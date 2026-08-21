# frozen_string_literal: true

require "securerandom"

module Buildkite::TestCollector
  module OTel
    DEFAULT_ENDPOINT = "https://tests-otlp.buildkite.com/v1/traces"

    RESULT_ATTRIBUTE = "test.case.result.status"

    # OpenTelemetry has no standard value for skipped tests.
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
    require_relative "otel/execution_child_forwarder"

    # Avoid duplicate IDs when test suites seed Ruby's global PRNG.
    module SecureRandomIdGenerator
      module_function

      def generate_trace_id
        generate(16)
      end

      def generate_span_id
        generate(8)
      end

      def generate(length)
        invalid_id = "\0" * length
        loop do
          id = SecureRandom.random_bytes(length)
          return id unless id == invalid_id
        end
      end
      private_class_method :generate
    end
    private_constant :SecureRandomIdGenerator

    class << self
      def enabled?
        !@tracer.nil?
      end

      def configure!(endpoint: DEFAULT_ENDPOINT, api_token: nil, run_env: {}, instrumentations: nil)
        return if enabled?

        # Non-empty selections are reserved for future :all and preset support.
        # Raising fails open by design: the rescue below reports the reserved
        # value and disables export rather than crashing the suite.
        unless instrumentations.nil? || instrumentations == []
          raise ArgumentError, "otel_instrumentations must be omitted or []"
        end

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/trace/propagation/trace_context"

        headers = request_headers(run_env, api_token)
        @execution_provider = build_execution_provider(endpoint, headers)
        @tracer = @execution_provider.tracer(TRACER_NAME, Buildkite::TestCollector::VERSION)
        configure_child_export(endpoint, headers, instrumentations)
      rescue LoadError, StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        shutdown
      end

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

      def with_test_span(span)
        return yield unless span

        OpenTelemetry::Context.with_value(execution_context_key, span.context.trace_id) do
          OpenTelemetry::Trace.with_span(span) { yield }
        end
      end

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
          finish_span(span)
        end

        span_duration(span)
      end

      def shutdown
        forwarder_error = deactivate_child_forwarder(@execution_child_forwarder)
        export_error = shutdown_exports(PROCESSOR_TIMEOUT_SECONDS)
        error = forwarder_error || export_error
        if error
          warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{error.class}: #{error.message}"
        end
      ensure
        @execution_provider = nil
        @execution_child_processor = nil
        @execution_child_forwarder = nil
        @tracer = nil
      end

      private

      def build_execution_provider(endpoint, headers)
        execution_processor = batch_processor(
          endpoint,
          headers,
          max_queue_size: ROOT_MAX_QUEUE_SIZE,
          max_export_batch_size: ROOT_MAX_EXPORT_BATCH_SIZE,
          schedule_delay: ROOT_SCHEDULE_DELAY_MILLISECONDS,
          metrics_reporter: RootSpanMetricsReporter.new,
        )
        execution_provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
          sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON,
          id_generator: SecureRandomIdGenerator,
        )
        execution_provider.add_span_processor(execution_processor)
        execution_provider
      rescue StandardError
        stop_processor(execution_processor)
        raise
      end

      def batch_processor(endpoint, headers, options = {})
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint,
          headers: headers,
        )
        OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter, **options)
      end

      def configure_child_export(endpoint, headers, instrumentations)
        provider = OpenTelemetry.tracer_provider
        collector_managed = provider.is_a?(OpenTelemetry::Internal::ProxyTracerProvider)
        unless collector_managed || provider.respond_to?(:add_span_processor)
          raise "existing OpenTelemetry tracer provider does not support adding a span processor"
        end

        child_processor = batch_processor(endpoint, headers)
        child_forwarder = ExecutionChildForwarder.new(
          child_processor,
          context_key: execution_context_key,
        )

        if collector_managed
          OpenTelemetry::SDK.configure do |config|
            config.id_generator = SecureRandomIdGenerator
            config.add_span_processor(child_forwarder)
            config.use_all if instrumentations.nil?
          end

          if OpenTelemetry.tracer_provider.is_a?(OpenTelemetry::Internal::ProxyTracerProvider)
            raise "OpenTelemetry SDK did not install a tracer provider"
          end
        else
          provider.add_span_processor(child_forwarder)
          unless instrumentations.nil?
            warn "[buildkite-test_collector] OpenTelemetry instrumentation selection ignored because the test suite already configured OpenTelemetry: #{instrumentations.inspect}"
          end
        end

        @execution_child_processor = child_processor
        @execution_child_forwarder = child_forwarder
      rescue StandardError => e
        deactivate_child_forwarder(child_forwarder)
        stop_processor(child_processor)
        warn "[buildkite-test_collector] OpenTelemetry child span export disabled: #{e.class}: #{e.message}; test.execution export remains enabled"
      end

      def execution_context_key
        @execution_context_key ||= OpenTelemetry::Context.create_key("buildkite.test.execution")
      end

      def shutdown_exports(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        error = nil

        [@execution_provider, @execution_child_processor].compact.each do |component|
          remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
          begin
            component.shutdown(timeout: remaining)
          rescue StandardError => e
            error ||= e
          end
        end

        error
      end

      def deactivate_child_forwarder(forwarder)
        forwarder&.shutdown
        nil
      rescue StandardError => e
        e
      end

      def stop_processor(processor)
        processor&.shutdown(timeout: 0)
      rescue StandardError
        nil
      end

      def finish_span(span)
        span.finish
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not finish OpenTelemetry test span: #{e.class}: #{e.message}"
      end

      def span_duration(span)
        return unless span.respond_to?(:to_span_data)

        data = span.to_span_data
        return unless data.start_timestamp && data.end_timestamp

        (data.end_timestamp - data.start_timestamp) / 1_000_000_000.0
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not read the OpenTelemetry test span's duration: #{e.class}: #{e.message}"
        nil
      end

      def trace_id(span)
        context = span.context
        return unless context.valid?

        context.hex_trace_id
      end

      # Link to the Agent job while keeping each execution a trace root.
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

      def request_headers(run_env, api_token)
        headers = { "Buildkite-Tests-Run-Key" => run_env["key"] }
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token
        headers
      end
    end
  end
end
