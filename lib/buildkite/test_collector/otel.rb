# frozen_string_literal: true

require "securerandom"
require "uri"

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

      # True when OTLP is the only upload method: the spans carry everything
      # the server needs to synthesize test executions, with no JSON upload
      # alongside.
      def otel_only?
        @otel_only == true
      end

      def configure!(endpoint: DEFAULT_ENDPOINT, api_token: nil, run_env: {}, instrumentations: nil, otel_only: false, resource_attributes: {})
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

        exempt_from_vcr(endpoint)

        headers = request_headers(run_env, api_token)

        # In OTLP-only mode the run-level detail (run key, branch, commit,
        # user tags) travels as the resource of the providers we create, so
        # every exported span carries it without repeating it per span.
        resource = otel_only ? run_resource(run_env, resource_attributes) : execution_resource
        @otel_only = true if otel_only

        @execution_provider = build_execution_provider(endpoint, headers, resource)
        @tracer = @execution_provider.tracer(TRACER_NAME, Buildkite::TestCollector::VERSION)
        configure_child_export(endpoint, headers, instrumentations, resource: otel_only ? resource : nil)
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

            if test.respond_to?(:otel_exception) && (exception = test.otel_exception)
              span.record_exception(exception)
            end
          end
        rescue StandardError => e
          warn "[buildkite-test_collector] Could not describe OpenTelemetry test span: #{e.class}: #{e.message}"
        ensure
          finish_span(span)
        end

        span_duration(span)
      end

      # Records a point-in-time annotation as an event on whichever span is
      # current, which during a test is the test's own trace. Safe to call
      # when export is off or nothing is recording: it just does nothing.
      def annotate(content)
        return unless enabled?

        span = OpenTelemetry::Trace.current_span
        return unless span.recording?

        span.add_event("test.annotation", attributes: { "buildkite.annotation" => content.to_s })
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not annotate OpenTelemetry test span: #{e.class}: #{e.message}"
      end

      # Pushes any finished spans out now without stopping export. Used at the
      # end of a suite when the process (and maybe another suite run) lives on.
      def force_flush
        @execution_provider&.force_flush(timeout: PROCESSOR_TIMEOUT_SECONDS)
        @execution_child_processor&.force_flush(timeout: PROCESSOR_TIMEOUT_SECONDS)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not flush OpenTelemetry spans: #{e.class}: #{e.message}"
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
        @otel_only = nil
      end

      private

      def build_execution_provider(endpoint, headers, resource)
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
          resource: resource,
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

      # Test suites that stub HTTP with VCR would otherwise intercept our
      # span export and fail the run (or record it into a cassette). VCR's
      # ignore_request hooks are additive, so this exempts exactly one
      # request shape - a POST to the configured OTLP endpoint - and leaves
      # the suite's network policy otherwise untouched. This runs from
      # RSpec's before(:suite), after the consumer's own VCR configuration
      # has loaded. WebMock used without VCR has no equivalent additive API,
      # so that case stays consumer-configured.
      def exempt_from_vcr(endpoint)
        return unless defined?(::VCR)

        target = URI(endpoint)
        ::VCR.configure do |vcr_config|
          vcr_config.ignore_request do |request|
            uri = URI(request.uri)
            request.method == :post &&
              uri.host == target.host &&
              uri.port == target.port &&
              uri.path == target.path
          rescue StandardError
            false
          end
        end
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not exempt the OTLP endpoint from VCR: #{e.class}: #{e.message}"
      end

      # In OTLP-only mode the collector-managed child provider carries the
      # same run resource as the execution provider, so instrumentation spans
      # and any spans the suite starts through the global tracer carry the
      # run's identity too. A suite-owned provider keeps its own resource.
      def configure_child_export(endpoint, headers, instrumentations, resource: nil)
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
            config.resource = resource if resource
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

      def execution_resource
        provider = OpenTelemetry.tracer_provider
        return provider.resource if provider.respond_to?(:resource)

        OpenTelemetry::SDK::Resources::Resource.default
      end

      # Describes the whole run once, on the resource, so every span carries it
      # without repeating it: which run this is, where it came from, and any
      # tags the user gave to configure.
      def run_resource(run_env, resource_attributes)
        attributes = {
          "service.name" => ENV["BUILDKITE_TEST_ENGINE_SUITE_SLUG"] || "buildkite-test-collector",
          "service.namespace" => ENV["BUILDKITE_ORGANIZATION_SLUG"],
          "service.instance.id" => run_env["job_id"],
          "buildkite.test.run.key" => run_env["key"],
          "buildkite.test.run.url" => run_env["url"],
          "buildkite.test.run.branch" => run_env["branch"],
          "buildkite.test.run.commit_sha" => run_env["commit_sha"],
          "buildkite.test.run.number" => run_env["number"],
          "buildkite.test.run.job_id" => run_env["job_id"],
          "buildkite.test.run.message" => run_env["message"],
          "buildkite.test.run.build_id" => ENV["BUILDKITE_BUILD_ID"],
          "buildkite.test.run.step_id" => ENV["BUILDKITE_STEP_ID"],
          "buildkite.test.collector.name" => run_env["collector"],
          "buildkite.test.collector.version" => run_env["version"],
          "test.framework.name" => Buildkite::TestCollector.test_runner,
        }
        if defined?(RSpec::Core::Version::STRING)
          attributes["test.framework.version"] = RSpec::Core::Version::STRING
        end

        user_attributes = (resource_attributes || {}).map { |key, value| [key.to_s, value.to_s] }.to_h

        OpenTelemetry::SDK::Resources::Resource.default.merge(
          OpenTelemetry::SDK::Resources::Resource.create(
            attributes.reject { |_, value| value.nil? }.merge(user_attributes)
          )
        )
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
