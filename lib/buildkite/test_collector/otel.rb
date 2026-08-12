# frozen_string_literal: true

module Buildkite::TestCollector
  # Experimental OpenTelemetry span emission.
  module OTel
    EXECUTION_EXTERNAL_ID_ATTRIBUTE = "execution.externalId"
    EXECUTION_TAG_ATTRIBUTE_PREFIX = "buildkite.test.execution.tag."
    TEST_RESULT_STATUS_ATTRIBUTE = "test.case.result.status"
    BUILDKITE_RESULT_STATUS_ATTRIBUTE = "buildkite.test.case.result.status"
    PROCESSOR_TIMEOUT_SECONDS = 5
    OIDC_TOKEN_LIFETIME_SECONDS = 3600

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
        !@tracer.nil?
      end

      def configure!(endpoint:, run_env: {})
        return if enabled?

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/instrumentation/all"

        resource = OpenTelemetry::SDK::Resources::Resource.create(
          resource_attributes(run_env)
        )
        exporter = ResourceMergingExporter.new(
          OpenTelemetry::Exporter::OTLP::Exporter.new(
            endpoint: endpoint,
            headers: request_headers(run_env),
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
      rescue LoadError, StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        shutdown
      end

      def start_test_span
        return [nil, nil] unless enabled?

        # Join the independently ingested upload and span without dangling IDs for unsampled spans.
        external_id = SecureRandom.uuid_v7
        link = agent_link
        span = @tracer.start_span(
          "test.execution",
          with_parent: OpenTelemetry::Context.empty,
          attributes: { EXECUTION_EXTERNAL_ID_ATTRIBUTE => external_id },
          kind: :internal,
          links: [link].compact,
        )
        [span, span.context.trace_flags.sampled? ? external_id : nil]
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not start OpenTelemetry test span: #{e.class}: #{e.message}"
        [nil, nil]
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

      def shutdown
        @processor&.shutdown(timeout: PROCESSOR_TIMEOUT_SECONDS)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{e.class}: #{e.message}"
      ensure
        @processor = nil
        @tracer = nil
      end

      private

      # The /v1/traces endpoint authenticates with an agent OIDC token whose
      # audience is the suite URL; the job ID is derived server-side from the
      # token, so it is no longer sent as a header.
      def request_headers(run_env)
        {
          "Buildkite-Test-Run-Key" => run_env["key"],
          "Authorization" => "Token #{oidc_token!}",
        }
      end

      def oidc_token!
        token = ENV["BUILDKITE_ANALYTICS_OTLP_OIDC_TOKEN"]
        return token unless token.to_s.empty?

        audience = ENV["BUILDKITE_ANALYTICS_OTLP_OIDC_AUDIENCE"]
        if audience.to_s.empty?
          raise "OTLP export requires BUILDKITE_ANALYTICS_OTLP_OIDC_TOKEN or " \
            "BUILDKITE_ANALYTICS_OTLP_OIDC_AUDIENCE (the suite URL) to authenticate"
        end

        require "open3"
        output, status = Open3.capture2(
          "buildkite-agent", "oidc", "request-token",
          "--audience", audience,
          "--lifetime", OIDC_TOKEN_LIFETIME_SECONDS.to_s,
        )
        raise "buildkite-agent oidc request-token failed" unless status.success?

        output.strip
      end

      def resource_attributes(run_env)
        job_id = ENV["BUILDKITE_JOB_ID"]
        tag = ENV["BUILDKITE_TAG"]
        tag = nil if tag&.empty?
        branch = ENV["BUILDKITE_BRANCH"]
        attributes = {
          "buildkite.test.run.key" => run_env["key"],
          "buildkite.job.id" => job_id,
          "cicd.pipeline.run.id" => ENV["BUILDKITE_BUILD_ID"],
          "cicd.pipeline.task.run.id" => job_id,
          "cicd.pipeline.run.url.full" => ENV["BUILDKITE_BUILD_URL"],
          "cicd.pipeline.name" => ENV["BUILDKITE_PIPELINE_SLUG"],
          "vcs.ref.head.revision" => ENV["BUILDKITE_COMMIT"],
          "vcs.ref.head.name" => tag || branch,
          "vcs.ref.type" => tag ? "tag" : "branch",
        }
        attributes.select { |_, value| value && !value.to_s.empty? }
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

    end
  end
end
