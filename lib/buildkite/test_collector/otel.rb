# frozen_string_literal: true

require "uri"

module Buildkite::TestCollector
  # Experimental OpenTelemetry span emission.
  module OTel
    EXECUTION_EXTERNAL_ID_ATTRIBUTE = "execution.externalId"
    EXECUTION_TAG_ATTRIBUTE_PREFIX = "buildkite.test.execution.tag."

    class << self
      def enabled?
        @enabled == true
      end

      def configure!(endpoint:, api_token: nil, run_env: {})
        return if @enabled

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/instrumentation/all"

        headers = {}
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token

        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint,
          headers: headers,
        )

        OpenTelemetry::SDK.configure do |c|
          c.resource = OpenTelemetry::SDK::Resources::Resource.create(
            resource_attributes(run_env)
          )
          c.add_span_processor(
            OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
          )
          # PoC shortcut: capture every available instrumentation.
          c.use_all
        end

        @tracer = OpenTelemetry.tracer_provider.tracer(
          "buildkite-test-collector", Buildkite::TestCollector::VERSION
        )
        @enabled = true
      rescue StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        @enabled = false
      end

      def in_test_span(name:, external_id: nil, attributes: {})
        return yield unless enabled?

        span_attributes = { EXECUTION_EXTERNAL_ID_ATTRIBUTE => external_id }
          .merge(attributes)
          .select { |_, value| !value.nil? }
        OpenTelemetry::Context.with_current(OpenTelemetry::Context.empty) do
          @tracer.in_span(name, attributes: span_attributes, kind: :internal) do |span|
            yield span
          end
        end
      end

      def record_test_result(span, result:, tags: {})
        return unless span

        status = case result
        when "passed" then "pass"
        when "failed" then "fail"
        when "skipped" then "skipped"
        end

        span.set_attribute("test.case.result.status", status) if status
        tags.each do |key, value|
          span.set_attribute("#{EXECUTION_TAG_ATTRIBUTE_PREFIX}#{key}", value)
        end
        span.status = OpenTelemetry::Trace::Status.error if result == "failed"
      end

      def force_flush
        return unless enabled?

        OpenTelemetry.tracer_provider.force_flush
      end

      def shutdown
        return unless enabled?

        OpenTelemetry.tracer_provider.shutdown
      ensure
        @enabled = false
      end

      private

      def resource_attributes(run_env)
        attributes = {
          "buildkite.test.run.id" => run_env["key"],
          "cicd.pipeline.run.id" => pipeline_run_id,
          "cicd.pipeline.run.url.full" => valid_http_url(run_env["url"]),
          "cicd.pipeline.name" => pipeline_name,
          "vcs.ref.head.revision" => run_env["commit_sha"],
          "vcs.ref.head.name" => run_env["branch"],
          "vcs.ref.type" => vcs_ref_type(run_env),
        }
        attributes.select { |_, value| value && !value.to_s.empty? }
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
