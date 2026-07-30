# frozen_string_literal: true

require "opentelemetry-helpers-sql-processor"
require "uri"

module Buildkite::TestCollector
  # Experimental OpenTelemetry span emission.
  module OTel
    EXECUTION_EXTERNAL_ID_ATTRIBUTE = "execution.externalId"
    EXECUTION_TAG_ATTRIBUTE_PREFIX = "buildkite.test.execution.tag."
    BUILDKITE_RESULT_STATUS_ATTRIBUTE = "buildkite.test.case.result.status"
    PROCESSOR_TIMEOUT = 5

    class ResourceMergingExporter
      def initialize(exporter, resource)
        @exporter = exporter
        @resource = resource
      end

      def export(span_data, timeout: nil)
        @exporter.export(
          span_data.map do |data|
            data.dup.tap do |copy|
              copy.attributes = export_attributes(data.attributes)
              copy.resource = export_resource(data.resource)
            end
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

      def export_attributes(attributes)
        statement_keys = ["db.statement", "db.query.text"].select do |key|
          attributes[key].is_a?(String)
        end
        return attributes if statement_keys.empty?

        attributes = attributes.dup
        db_system = attributes["db.system"] || attributes["db.system.name"]
        statement_keys.each do |key|
          normalized = normalize_sql(attributes[key], db_system)
          if normalized
            attributes[key] = normalized
          else
            attributes.delete(key)
          end
        end
        attributes.freeze
      end

      def normalize_sql(statement, db_system)
        adapter = sql_adapter(db_system)
        return unless adapter

        OpenTelemetry::Helpers::SqlProcessor.obfuscate_sql(
          statement,
          adapter: adapter,
        )
      rescue StandardError
        nil
      end

      def sql_adapter(db_system)
        case db_system
        when "postgresql" then :postgres
        when "mysql", "mariadb" then :mysql
        when "oracle.db" then :oracle
        when "sqlite", "oracle", "cassandra" then db_system.to_sym
        when "cockroachdb", "microsoft.sql_server", "other_sql" then :default
        end
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

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        require "opentelemetry/instrumentation/all"

        headers = {}
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token

        resource = OpenTelemetry::SDK::Resources::Resource.create(
          resource_attributes(run_env)
        )
        exporter = ResourceMergingExporter.new(
          OpenTelemetry::Exporter::OTLP::Exporter.new(
            endpoint: endpoint,
            headers: headers,
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
            c.resource = resource
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
      rescue StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        shutdown_processor(@processor)
        @processor = nil
        @tracer = nil
        @enabled = false
      end

      def start_test_span(name:, external_id: nil)
        return unless enabled?

        @tracer.start_span(
          name,
          with_parent: OpenTelemetry::Context.empty,
          attributes: { EXECUTION_EXTERNAL_ID_ATTRIBUTE => external_id }.compact,
          kind: :internal,
        )
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
            span.set_attribute("test.case.result.status", "pass")
          when "failed"
            span.set_attribute("test.case.result.status", "fail")
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

        @processor.force_flush(timeout: PROCESSOR_TIMEOUT)
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
        processor&.shutdown(timeout: PROCESSOR_TIMEOUT)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not shut down OpenTelemetry span export: #{e.class}: #{e.message}"
      end

      def resource_attributes(run_env)
        attributes = {
          "buildkite.test.run.id" => run_env["key"],
          "cicd.pipeline.run.id" => pipeline_run_id,
          "cicd.pipeline.run.url.full" => pipeline_run_url(run_env),
          "cicd.pipeline.name" => pipeline_name,
          "vcs.ref.head.revision" => run_env["commit_sha"],
          "vcs.ref.head.name" => vcs_ref_name(run_env),
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
