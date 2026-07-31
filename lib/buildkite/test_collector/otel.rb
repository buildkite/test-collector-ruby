# frozen_string_literal: true

require "uri"

module Buildkite::TestCollector
  # Experimental OpenTelemetry span emission.
  module OTel
    EXECUTION_EXTERNAL_ID_ATTRIBUTE = "execution.externalId"
    EXECUTION_TAG_ATTRIBUTE_PREFIX = "buildkite.test.execution.tag."
    TEST_RESULT_STATUS_ATTRIBUTE = "test.case.result.status"
    BUILDKITE_RESULT_STATUS_ATTRIBUTE = "buildkite.test.case.result.status"
    PROCESSOR_TIMEOUT_SECONDS = 5
    RUN_KEY_FORMAT = /\A[!-~]{1,255}\z/
    UUID_FORMAT = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/

    class ResourceMergingExporter
      def initialize(exporter, resource)
        @exporter = exporter
        @resource = resource
      end

      def export(span_data, timeout: nil)
        @exporter.export(
          span_data.map do |data|
            data.dup.tap { |copy| copy.resource = export_resource(data.resource) }
          end,
          timeout: timeout,
        )
      end

      def force_flush(timeout: nil)
        @exporter.force_flush(timeout: timeout)
      end

      def shutdown(timeout: nil)
        @exporter.shutdown(timeout: timeout)
      end

      private

      def export_resource(resource)
        attributes = resource.merge(@resource).attribute_enumerator.to_h
        command = attributes["process.command"]
        attributes["process.command"] = File.basename(command) if command.is_a?(String)
        OpenTelemetry::SDK::Resources::Resource.create(attributes)
      end
    end
    private_constant :ResourceMergingExporter

    class OwnedSpanProcessor
      def initialize(processor)
        @processor = processor
        @active = true
        @mutex = Mutex.new
      end

      def on_start(span, parent_context)
        @mutex.synchronize { @processor.on_start(span, parent_context) if @active }
      end

      def on_finish(span)
        @mutex.synchronize { @processor.on_finish(span) if @active }
      end

      def force_flush(timeout: nil)
        @mutex.synchronize do
          return success unless @active

          @processor.force_flush(timeout: timeout)
        end
      end

      def shutdown(timeout: nil)
        @mutex.synchronize do
          return success unless @active

          @active = false
          @processor.shutdown(timeout: timeout)
        end
      end

      private

      def success
        OpenTelemetry::SDK::Trace::Export::SUCCESS
      end
    end
    private_constant :OwnedSpanProcessor

    class << self
      def enabled?
        @enabled == true
      end

      def configure!(endpoint:, api_token: nil, run_env: {})
        return if @enabled

        run_key = run_env["key"]
        unless run_key.is_a?(String) && run_key.match?(RUN_KEY_FORMAT)
          raise ArgumentError, "a valid Buildkite test run key is required"
        end

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/instrumentation/all"

        resource = OpenTelemetry::SDK::Resources::Resource.create(
          resource_attributes(run_env)
        )
        exporter = ResourceMergingExporter.new(
          OpenTelemetry::Exporter::OTLP::Exporter.new(
            endpoint: endpoint,
            headers: request_headers(run_env, api_token),
          ),
          resource,
        )
        @processor = OwnedSpanProcessor.new(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
        )

        provider = OpenTelemetry.tracer_provider
        if provider.respond_to?(:add_span_processor)
          provider.add_span_processor(@processor)
          # PoC shortcut: capture every available instrumentation.
          OpenTelemetry::Instrumentation.registry.install_all
        elsif provider.is_a?(OpenTelemetry::Internal::ProxyTracerProvider)
          OpenTelemetry::SDK.configure do |c|
            c.add_span_processor(@processor)
            # PoC shortcut: capture every available instrumentation.
            c.use_all
          end
          provider = OpenTelemetry.tracer_provider
        else
          raise "existing OpenTelemetry tracer provider does not support adding a span processor"
        end

        @tracer = provider.tracer(
          "buildkite-test-collector", Buildkite::TestCollector::VERSION
        )
        @enabled = true
      rescue LoadError, StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        shutdown_processor(@processor)
        @processor = nil
        @tracer = nil
        @enabled = false
      end

      def start_test_span(name:, external_id: nil)
        return unless enabled?

        link = agent_link
        @tracer.start_span(
          name,
          with_parent: OpenTelemetry::Context.empty,
          attributes: { EXECUTION_EXTERNAL_ID_ATTRIBUTE => external_id }.compact,
          kind: :internal,
          links: [link].compact,
        )
      end

      def sampled?(span)
        span&.context&.trace_flags&.sampled? == true
      end

      def with_test_span(span)
        return yield unless span

        OpenTelemetry::Trace.with_span(span) { yield }
      end

      def finish_test_span(span, result:, tags: {}, attributes: {})
        return unless span

        begin
          attributes.each do |key, value|
            span.set_attribute(key, value) unless value.nil?
          end

          case result
          when "passed"
            span.set_attribute(TEST_RESULT_STATUS_ATTRIBUTE, "pass")
          when "failed"
            span.set_attribute(TEST_RESULT_STATUS_ATTRIBUTE, "fail")
          when "skipped"
            span.set_attribute(BUILDKITE_RESULT_STATUS_ATTRIBUTE, "skipped")
          end
          tags.each do |key, value|
            span.set_attribute("#{EXECUTION_TAG_ATTRIBUTE_PREFIX}#{key}", value)
          end
          span.status = OpenTelemetry::Trace::Status.error if result == "failed"
        rescue StandardError => e
          warn "[buildkite-test_collector] Could not finalize OpenTelemetry test span: #{e.class}: #{e.message}"
        ensure
          begin
            span.finish
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not finish OpenTelemetry test span: #{e.class}: #{e.message}"
          end
        end
      end

      def force_flush
        return unless enabled?

        @processor.force_flush(timeout: PROCESSOR_TIMEOUT_SECONDS)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not flush OpenTelemetry spans: #{e.class}: #{e.message}"
      end

      def shutdown
        return unless enabled?

        shutdown_processor(@processor)
      ensure
        @enabled = false
        @processor = nil
        @tracer = nil
      end

      private

      def shutdown_processor(processor)
        processor&.shutdown(timeout: PROCESSOR_TIMEOUT_SECONDS)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{e.class}: #{e.message}"
      end

      def request_headers(run_env, api_token)
        headers = { "Buildkite-Test-Run-Key" => run_env["key"] }
        job_id = buildkite_job_id(run_env)
        headers["Buildkite-Test-Job-ID"] = job_id if job_id
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token
        headers
      end

      def resource_attributes(run_env)
        job_id = buildkite_job_id(run_env)
        attributes = {
          "buildkite.test.run.key" => run_env["key"],
          "buildkite.job.id" => job_id,
          "cicd.pipeline.run.id" => pipeline_run_id,
          "cicd.pipeline.task.run.id" => job_id,
          "cicd.pipeline.run.url.full" => pipeline_run_url(run_env),
          "cicd.pipeline.name" => pipeline_name,
          "vcs.ref.head.revision" => run_env["commit_sha"],
          "vcs.ref.head.name" => vcs_ref_name(run_env),
          "vcs.ref.type" => vcs_ref_type(run_env),
        }
        attributes.select { |_, value| value && !value.to_s.empty? }
      end

      def buildkite_job_id(run_env)
        job_id = run_env["job_id"]
        job_id if run_env["CI"] == "buildkite" && job_id.is_a?(String) && job_id.match?(UUID_FORMAT)
      end

      def agent_link
        carrier = {
          "traceparent" => ENV["TRACEPARENT"],
          "tracestate" => ENV["TRACESTATE"],
        }.compact
        return if carrier.empty?

        propagator = OpenTelemetry::Trace::Propagation::TraceContext::TextMapPropagator.new
        context = propagator.extract(carrier, context: OpenTelemetry::Context.empty)
        span_context = OpenTelemetry::Trace.current_span(context).context
        OpenTelemetry::Trace::Link.new(span_context) if span_context.valid?
      rescue StandardError
        nil
      end

      def pipeline_run_id
        return ENV["BUILDKITE_BUILD_ID"] if ENV["BUILDKITE_BUILD_ID"]
        return ENV["GITHUB_RUN_ID"] if ENV["GITHUB_RUN_ID"]
        return ENV["CIRCLE_WORKFLOW_ID"] if ENV["CIRCLE_WORKFLOW_ID"]
        return ENV["CI_BUILD_ID"] if ENV["CI_NAME"] == "codeship"
      end

      def pipeline_name
        return ENV["BUILDKITE_PIPELINE_SLUG"] if ENV["BUILDKITE_BUILD_ID"]
        return ENV["GITHUB_WORKFLOW"] if ENV["GITHUB_RUN_ID"]
      end

      def pipeline_run_url(run_env)
        return if run_env["CI"] == "codeship" && !ENV["BUILDKITE_ANALYTICS_URL"]

        valid_http_url(run_env["url"])
      end

      def vcs_ref_name(run_env)
        return ENV["BUILDKITE_TAG"] if ENV["BUILDKITE_TAG"] && !ENV["BUILDKITE_TAG"].empty?

        run_env["branch"]
      end

      def vcs_ref_type(run_env)
        return ENV["GITHUB_REF_TYPE"] if %w[branch tag].include?(ENV["GITHUB_REF_TYPE"])
        return "tag" if ENV["BUILDKITE_TAG"] && !ENV["BUILDKITE_TAG"].empty?
        return "branch" if run_env["branch"] && !run_env["branch"].empty?
      end

      def valid_http_url(value)
        return unless value

        uri = URI.parse(value)
        value if %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
