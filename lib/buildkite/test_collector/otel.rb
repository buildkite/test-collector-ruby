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
    # So after we shut down, we can't remove ourselves and spans would just
    # pile up with nothing reading them. This wrapper fixes that by quietly
    # ignoring everything once we're shut down, instead of leaving a real
    # processor behind that nobody empties.
    class OwnedSpanProcessor
      def initialize(processor)
        @processor = processor
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
        @processor.shutdown(timeout: timeout)
      end
    end
    private_constant :OwnedSpanProcessor

    class << self
      # True once OpenTelemetry has been turned on and set up successfully.
      def enabled?
        !@tracer.nil?
      end

      # Turns on OpenTelemetry span export: loads the OTel libraries, sets up
      # an exporter that sends spans to Buildkite, and starts instrumenting
      # everything OpenTelemetry knows how to instrument. If anything goes
      # wrong (missing gems, bad setup, etc.), we log a warning and leave
      # OTel turned off rather than crashing the test run.
      def configure!(endpoint: DEFAULT_ENDPOINT, api_token: nil, run_env: {})
        return if enabled?

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/trace/propagation/trace_context"

        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint,
          headers: request_headers(run_env, api_token),
        )
        @processor = OwnedSpanProcessor.new(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
        )

        provider = install_processor(@processor)

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
        @processor&.shutdown(timeout: PROCESSOR_TIMEOUT_SECONDS)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{e.class}: #{e.message}"
      ensure
        @processor = nil
        @tracer = nil
      end

      private

      # We don't set up our own tracer provider. Instead we plug our
      # processor into whatever provider the test suite is already using
      # (its own, or OpenTelemetry's default one), and only take
      # responsibility for shutting down our own processor later.
      def install_processor(processor)
        provider = OpenTelemetry.tracer_provider

        if provider.respond_to?(:add_span_processor)
          # The suite runs its own OpenTelemetry. Its instrumentation already
          # feeds this provider, so our processor sees those spans without us
          # installing anything. Installing our own would also push spans the
          # suite never asked for into the suite's own exporters.
          provider.add_span_processor(processor)
          provider
        elsif provider.is_a?(OpenTelemetry::Internal::ProxyTracerProvider)
          OpenTelemetry::SDK.configure do |c|
            c.id_generator = SecureRandomIdGenerator
            c.add_span_processor(processor)
          end
          # Nobody else is instrumenting, so bring our own. Everything for now:
          # narrowing this to a hand picked set is a decision for once
          # dogfooding shows which spans are worth the noise.
          require "opentelemetry/instrumentation/all"
          OpenTelemetry::Instrumentation.registry.install_all
          OpenTelemetry.tracer_provider
        else
          raise "existing OpenTelemetry tracer provider does not support adding a span processor"
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
        headers = { "Buildkite-Tests-Run-Key" => run_env["key"] }
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token
        headers
      end
    end
  end
end
