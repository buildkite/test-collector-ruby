# frozen_string_literal: true

require "securerandom"

module Buildkite::TestCollector
  # Opt-in OpenTelemetry span emission.
  module OTel
    DEFAULT_ENDPOINT = "https://tests-otlp.buildkite.com/v1/traces"

    DEFAULT_INSTRUMENTATIONS = [:pg, :mysql2, :trilogy].freeze
    BUNDLED_INSTRUMENTATIONS = {
      pg: ["opentelemetry-instrumentation-pg", "OpenTelemetry::Instrumentation::PG"].freeze,
      mysql2: ["opentelemetry-instrumentation-mysql2", "OpenTelemetry::Instrumentation::Mysql2"].freeze,
      trilogy: ["opentelemetry-instrumentation-trilogy", "OpenTelemetry::Instrumentation::Trilogy"].freeze,
    }.freeze

    INSTRUMENTATION_NAMESPACE = "OpenTelemetry::Instrumentation::"
    # Derived from each instrumentation gem's installer because OpenTelemetry
    # does not expose patch targets as metadata. Review these paths when adding
    # an instrumentation or changing its supported gem version.
    PATCH_TARGET_CONSTANT_PATHS = {
      "OpenTelemetry::Instrumentation::PG" => ["PG::Connection"].freeze,
      "OpenTelemetry::Instrumentation::Mysql2" => ["Mysql2::Client"].freeze,
      "OpenTelemetry::Instrumentation::Trilogy" => ["Trilogy"].freeze,
    }.freeze
    private_constant :DEFAULT_INSTRUMENTATIONS, :BUNDLED_INSTRUMENTATIONS,
      :INSTRUMENTATION_NAMESPACE, :PATCH_TARGET_CONSTANT_PATHS

    RESULT_ATTRIBUTE = "test.case.result.status"

    # OpenTelemetry defines "pass" and "fail", which we have to use where they
    # apply, and allows a custom value where none does. Hence "skipped", which it
    # has no word for.
    RESULT_STATUSES = {
      "passed" => "pass",
      "failed" => "fail",
      "skipped" => "skipped",
    }.freeze

    PROCESSOR_TIMEOUT_SECONDS = 30

    TRACER_NAME = "buildkite-test-collector"

    ROOT_SPAN_NAME = "test.execution"
    ROOT_MAX_QUEUE_SIZE = 8_192
    ROOT_MAX_EXPORT_BATCH_SIZE = 512
    ROOT_SCHEDULE_DELAY_MILLISECONDS = 1_000

    require_relative "otel/root_span_metrics_reporter"
    require_relative "otel/root_preserving_span_processor"

    # OpenTelemetry's default ID generator uses Ruby's global PRNG. Test suites
    # can seed that PRNG, making separate processes generate the same trace IDs.
    # Use the operating system's random source for the provider we create instead.
    module SecureRandomIdGenerator
      module_function

      def generate_trace_id
        generate(16)
      end

      def generate_span_id
        generate(8)
      end

      def generate(length)
        id = SecureRandom.random_bytes(length) until id && id != "\0" * length
        id
      end
      private_class_method :generate
    end
    private_constant :SecureRandomIdGenerator

    class << self
      # True once OpenTelemetry has been turned on and set up successfully.
      def enabled?
        !@tracer.nil?
      end

      # Turns on OpenTelemetry span export: loads the OTel libraries, sets up
      # an exporter that sends spans to Buildkite, and installs the selected
      # instrumentation when the collector owns the provider. If anything goes
      # wrong (missing gems, bad setup, etc.), we log a warning and leave OTel
      # turned off rather than crashing the test run.
      def configure!(endpoint: DEFAULT_ENDPOINT, api_token: nil, run_env: {}, instrumentations: nil)
        return if enabled?

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/trace/propagation/trace_context"

        headers = request_headers(run_env, api_token)
        @processor = build_span_processor(endpoint, headers)

        provider = install_processor(@processor, instrumentations)

        @tracer = provider.tracer(TRACER_NAME, Buildkite::TestCollector::VERSION)
      rescue LoadError, StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        shutdown
      end

      # Starts a new span for one test and gives back both the span and its
      # trace ID. We attach that trace ID to the test result we upload later,
      # so the two pieces of data can be matched up once they both arrive on
      # the server.
      def start_test_span
        return [nil, nil] unless enabled?

        span = @tracer.start_span(
          ROOT_SPAN_NAME,
          with_parent: OpenTelemetry::Context.empty,
          links: job_span_links,
          kind: :internal,
        )
        [span, trace_id(span)]
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not start OpenTelemetry test span: #{e.class}: #{e.message}"
        [nil, nil]
      end

      # Runs the given block "inside" the span, so anything that happens
      # during the block (like other instrumented calls) gets recorded as
      # part of this test. If there's no span (OTel isn't turned on), it
      # just runs the block as normal.
      def with_test_span(span)
        return yield unless span

        OpenTelemetry::Trace.with_span(span) { yield }
      end

      # Records what the test was and how it went, then marks the span as done,
      # and hands back how long the span says the test took. Safe to call even
      # if there's no span. `test` is asked for its `otel_attributes` and
      # `otel_result` here rather than by the caller, so nothing is built when
      # export is off and a bad value can't leave the span open or fail the test.
      def finish_test_span(span, test: nil)
        return unless span

        begin
          if test
            test.otel_attributes.each do |key, value|
              span.set_attribute(key, value) unless value.nil?
            end

            result = test.otel_result
            status = RESULT_STATUSES[result]
            span.set_attribute(RESULT_ATTRIBUTE, status) if status
            span.status = OpenTelemetry::Trace::Status.error if result == "failed"
          end
        rescue StandardError => e
          warn "[buildkite-test_collector] Could not describe OpenTelemetry test span: #{e.class}: #{e.message}"
        ensure
          begin
            span.finish
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not finish OpenTelemetry test span: #{e.class}: #{e.message}"
          end
        end

        span_duration(span)
      end

      # Turns off span export and flushes anything left in the queue. Safe to
      # call even if we were never turned on.
      def shutdown
        @processor&.shutdown(timeout: PROCESSOR_TIMEOUT_SECONDS)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{e.class}: #{e.message}"
      ensure
        @processor = nil
        @tracer = nil
      end

      private

      def build_span_processor(endpoint, headers)
        root_processor = batch_processor(
          endpoint,
          headers,
          max_queue_size: ROOT_MAX_QUEUE_SIZE,
          max_export_batch_size: ROOT_MAX_EXPORT_BATCH_SIZE,
          schedule_delay: ROOT_SCHEDULE_DELAY_MILLISECONDS,
          metrics_reporter: RootSpanMetricsReporter.new,
        )
        children_processor = batch_processor(endpoint, headers)
        RootPreservingSpanProcessor.new(
          root: root_processor,
          children: children_processor,
        )
      rescue StandardError
        [root_processor, children_processor].compact.each do |processor|
          begin
            processor.shutdown(timeout: 0)
          rescue StandardError
            nil
          end
        end
        raise
      end

      def batch_processor(endpoint, headers, options = {})
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint,
          headers: headers,
        )
        OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter, **options)
      end

      # We don't set up our own tracer provider. Instead we plug our
      # processor into whatever provider the test suite is already using
      # (its own, or OpenTelemetry's default one), and only take
      # responsibility for shutting down our own processor later.
      def install_processor(processor, instrumentations)
        provider = OpenTelemetry.tracer_provider

        if provider.respond_to?(:add_span_processor)
          # The suite runs its own OpenTelemetry. Its instrumentation already
          # feeds this provider, so our processor sees those spans without us
          # installing anything. Installing our own would also push spans the
          # suite never asked for into the suite's own exporters.
          provider.add_span_processor(processor)
          unless instrumentations.nil?
            warn "[buildkite-test_collector] OpenTelemetry instrumentation selection ignored because the test suite already configured OpenTelemetry: #{instrumentations.inspect}"
          end
          provider
        elsif provider.is_a?(OpenTelemetry::Internal::ProxyTracerProvider)
          OpenTelemetry::SDK.configure do |c|
            c.id_generator = SecureRandomIdGenerator
            c.add_span_processor(processor)
          end
          install_instrumentations(instrumentations)
          OpenTelemetry.tracer_provider
        else
          raise "existing OpenTelemetry tracer provider does not support adding a span processor"
        end
      end

      def install_instrumentations(selection)
        selected_instrumentations(selection).each do |entry|
          install_instrumentation(entry)
        end
      end

      def selected_instrumentations(selection)
        entries = selection.nil? ? DEFAULT_INSTRUMENTATIONS : Array(selection)
        entries.flat_map { |entry| entry == :defaults ? DEFAULT_INSTRUMENTATIONS : [entry] }.uniq
      end

      def install_instrumentation(entry)
        collector_provided = entry.is_a?(Symbol)
        if collector_provided
          bundled = BUNDLED_INSTRUMENTATIONS[entry]
          unless bundled
            warn "[buildkite-test_collector] Unknown OpenTelemetry instrumentation: #{entry.inspect}"
            return
          end

          require_path, name = bundled
          require require_path
        elsif entry.is_a?(String)
          name = entry
        else
          warn "[buildkite-test_collector] Unknown OpenTelemetry instrumentation: #{entry.inspect}"
          return
        end

        instrumentation = OpenTelemetry::Instrumentation.registry.lookup(name)
        unless instrumentation
          warn "[buildkite-test_collector] OpenTelemetry instrumentation unavailable: #{name} is not registered"
          return
        end
        unless instrumentation.present?
          warn "[buildkite-test_collector] OpenTelemetry instrumentation unavailable: #{name} target library is not loaded"
          return
        end
        unless instrumentation.compatible?
          warn "[buildkite-test_collector] OpenTelemetry instrumentation incompatible: #{name}"
          return
        end

        if collector_provided
          # Prepending is irreversible, so do not patch a target another library has already patched.
          conflict = foreign_patch(name)
          if conflict
            patch, target = conflict
            warn "[buildkite-test_collector] OpenTelemetry instrumentation unsafe: #{name} skipped; foreign patch #{module_name(patch)} found on #{target}"
            return
          end
        end

        installed = instrumentation.install
        unless installed
          warn "[buildkite-test_collector] OpenTelemetry instrumentation failed: #{name} could not be installed"
        end
      rescue LoadError => e
        name ||= entry.inspect
        warn "[buildkite-test_collector] OpenTelemetry instrumentation unavailable: #{name}: #{e.message}"
      rescue StandardError => e
        name ||= entry.inspect
        warn "[buildkite-test_collector] OpenTelemetry instrumentation failed: #{name}: #{e.class}: #{e.message}"
      end

      # Instrumentation gems do not expose their patch targets, and their
      # registered names do not reliably identify the constants they patch.
      # Keep every target we inspect explicit instead of guessing.
      def patch_targets(name)
        paths = PATCH_TARGET_CONSTANT_PATHS[name]
        paths.map { |path| resolve_constant(path) }.compact.uniq
      end

      def resolve_constant(path)
        path.split("::").inject(::Object) do |namespace, constant|
          namespace.const_get(constant, false)
        end
      rescue NameError
        nil
      end

      def foreign_patch(name)
        patch_targets(name).each do |target|
          target_name = module_name(target)
          [
            [target, target_name],
            [target.singleton_class, "#{target_name}.singleton_class"],
          ].each do |owner, owner_name|
            target_index = owner.ancestors.index(owner)
            next unless target_index

            patch = owner.ancestors[0...target_index].find do |ancestor|
              !module_name(ancestor).start_with?(INSTRUMENTATION_NAMESPACE)
            end
            return [patch, owner_name] if patch
          end
        end
        nil
      end

      def module_name(mod)
        name = mod.respond_to?(:name) && mod.name
        name && !name.empty? ? name : mod.inspect
      end

      # How long the finished span says the test took, in seconds. We report this
      # as the execution's duration too, so the two never disagree. Both are
      # worked out from the monotonic clock, so neither is thrown off if the
      # system clock moves mid-run. Anything that isn't a real recorded span
      # (unsampled, or a stand-in) has nothing to read, and gets nil.
      def span_duration(span)
        return unless span.respond_to?(:to_span_data)

        data = span.to_span_data
        return unless data.start_timestamp && data.end_timestamp

        (data.end_timestamp - data.start_timestamp) / 1_000_000_000.0
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not read the OpenTelemetry test span's duration: #{e.class}: #{e.message}"
        nil
      end

      # Reads the trace ID that OpenTelemetry already generated for this span.
      # We don't need to make up our own ID, since the SDK creates one
      # automatically for a span that has no parent. We return it even if
      # this trace won't end up being sampled, since deciding that isn't our
      # job.
      def trace_id(span)
        context = span.context
        return unless context.valid?

        context.hex_trace_id
      end

      # The Agent propagates the current job trace context through these
      # environment variables. Link to it without making it the parent: every
      # test execution must remain the root of its own trace.
      def job_span_links
        carrier = {
          "traceparent" => ENV["TRACEPARENT"],
          "tracestate" => ENV["TRACESTATE"],
        }
        context = OpenTelemetry::Trace::Propagation::TraceContext
          .text_map_propagator
          .extract(carrier, context: OpenTelemetry::Context.empty)
        span_context = OpenTelemetry::Trace.current_span(context).context
        return [] unless span_context.valid?

        [OpenTelemetry::Trace::Link.new(span_context)]
      rescue StandardError
        []
      end

      # Builds the HTTP headers sent with every exported span. The server
      # figures out which test run this belongs to from the run key, and
      # figures out which job sent it from the auth token, so we don't need
      # to send that separately.
      def request_headers(run_env, api_token)
        headers = { "Buildkite-Tests-Run-Key" => run_env["key"] }
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token
        headers
      end
    end
  end
end
