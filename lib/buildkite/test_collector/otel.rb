# frozen_string_literal: true

require "securerandom"

module Buildkite::TestCollector
  # Opt-in OpenTelemetry span emission.
  module OTel
    DEFAULT_ENDPOINT = "https://test-otlp.buildkite.com/v1/traces"

    RESULT_ATTRIBUTE = "test.case.result.status"

    # OpenTelemetry defines "pass" and "fail", which we have to use where they
    # apply, and allows a custom value where none does. Hence "skipped", which it
    # has no word for.
    RESULT_STATUSES = {
      "passed" => "pass",
      "failed" => "fail",
      "skipped" => "skipped",
    }.freeze

    PROCESSOR_TIMEOUT_SECONDS = 5

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

    # Once you give OpenTelemetry a processor, there's no way to take it back.
    # This wrapper can either own the processor's lifecycle or just forward to
    # it. The latter lets a host provider send us spans without being able to
    # shut down the collector-owned processor it forwards to.
    class ManagedSpanProcessor
      def initialize(processor, owns_lifecycle: true)
        @processor = processor
        @owns_lifecycle = owns_lifecycle
        @active = true
      end

      def on_start(span, parent_context)
        @processor.on_start(span, parent_context) if @active
      end

      def on_finish(span)
        @processor.on_finish(span) if @active
      end

      # OpenTelemetry checks the result we return, so we always need to give
      # it a valid "success" value, even after we've stopped doing anything.
      def force_flush(timeout: nil)
        return OpenTelemetry::SDK::Trace::Export::SUCCESS unless @active

        @processor.force_flush(timeout: timeout)
      end

      def shutdown(timeout: nil)
        return OpenTelemetry::SDK::Trace::Export::SUCCESS unless @active

        @active = false
        return OpenTelemetry::SDK::Trace::Export::SUCCESS unless @owns_lifecycle

        @processor.shutdown(timeout: timeout)
      end
    end
    private_constant :ManagedSpanProcessor

    class << self
      # True once OpenTelemetry has been turned on and set up successfully.
      def enabled?
        !@tracer.nil?
      end

      # Turns on OpenTelemetry span export: loads the OTel libraries and sets up
      # an exporter that sends spans to Buildkite. If we create the provider, we
      # install the instrumentation gems already loaded by the suite, optionally
      # limited to an explicit list. If anything goes wrong (missing gems, bad
      # setup, etc.), we log a warning and leave OTel turned off rather than
      # crashing the test run.
      def configure!(endpoint: DEFAULT_ENDPOINT, api_token: nil, run_env: {}, instrumentations: nil)
        return if enabled?

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/trace/propagation/trace_context"

        headers = request_headers(run_env, api_token)
        @processor = build_processor(endpoint, headers)
        provider = OpenTelemetry.tracer_provider
        if provider.respond_to?(:add_span_processor)
          # Host instrumentation can produce enough spans to fill the SDK's
          # bounded batch queue. Keep roots in their own queue so that child
          # span backpressure cannot evict them before export.
          @child_processor = build_processor(endpoint, headers)
        end

        provider = install_processor(
          @processor,
          instrumentations,
          child_processor: @child_processor,
        )

        @tracer = provider.tracer(
          "buildkite-test-collector", Buildkite::TestCollector::VERSION
        )
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
          "test.execution",
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
        [@host_processor, @processor, @child_processor].compact.each do |processor|
          begin
            processor.shutdown(timeout: PROCESSOR_TIMEOUT_SECONDS)
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{e.class}: #{e.message}"
          end
        end
      ensure
        @host_processor = nil
        @processor = nil
        @child_processor = nil
        @tracer = nil
      end

      private

      def build_processor(endpoint, headers)
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint,
          headers: headers,
        )
        ManagedSpanProcessor.new(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
        )
      end

      # Use the suite's provider for its instrumented child spans, but create the
      # test root with a private provider whose IDs cannot be affected by the
      # suite seeding Ruby's PRNG. Each provider has its own processor so heavy
      # child-span traffic cannot evict roots from the bounded batch queue.
      # Without a suite provider, configure the default SDK provider and use one
      # processor for both roots and children.
      def install_processor(processor, instrumentations = nil, child_processor: nil)
        provider = OpenTelemetry.tracer_provider

        if provider.respond_to?(:add_span_processor)
          root_provider_options = { id_generator: SecureRandomIdGenerator }
          if provider.respond_to?(:resource)
            root_provider_options[:resource] = provider.resource
          end
          root_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(**root_provider_options)
          root_provider.add_span_processor(processor)

          # The host owns this wrapper's lifecycle. Its shutdown only stops
          # forwarding; it cannot shut down the collector-owned child processor.
          @host_processor = ManagedSpanProcessor.new(child_processor, owns_lifecycle: false)
          provider.add_span_processor(@host_processor)
          root_provider
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

      # Instrumentation patches application libraries globally and can conflict
      # with other APM libraries. By default, install every registered entry: the
      # collector loads none itself, so registrations come from instrumentation
      # gems the suite loaded. An explicit list (including an empty one) narrows it.
      def install_instrumentations(instrumentation_names)
        registry = OpenTelemetry::Instrumentation.registry

        if instrumentation_names.nil?
          begin
            registry.install_all
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not install loaded OpenTelemetry instrumentation: #{e.class}: #{e.message}"
          end
          return
        end

        instrumentation_names = Array(instrumentation_names)
        return if instrumentation_names.empty?

        instrumentation_names.each do |name|
          begin
            instrumentation = registry.lookup(name)
            unless instrumentation
              warn "[buildkite-test_collector] OpenTelemetry instrumentation is not available: #{name.inspect}"
              next
            end

            unless instrumentation.present?
              warn "[buildkite-test_collector] OpenTelemetry instrumentation dependency is not available: #{name.inspect}"
              next
            end

            unless instrumentation.compatible?
              warn "[buildkite-test_collector] OpenTelemetry instrumentation is not compatible: #{name.inspect}"
              next
            end

            registry.install([name])
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not install OpenTelemetry instrumentation #{name.inspect}: #{e.class}: #{e.message}"
          end
        end
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
        headers = { "Buildkite-Test-Run-Key" => run_env["key"] }
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token
        headers
      end
    end
  end
end
