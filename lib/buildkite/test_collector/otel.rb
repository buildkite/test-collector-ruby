# frozen_string_literal: true

module Buildkite::TestCollector
  # Experimental OpenTelemetry span emission.
  #
  # OpenTelemetry gems are soft dependencies so missing gems disable span export
  # without affecting test collection. See docs/opentelemetry-architecture-notes.md
  # for the PoC's architecture and production tradeoffs.
  module OTel
    EXECUTION_EXTERNAL_ID_ATTRIBUTE = "execution.externalId"

    class << self
      def enabled?
        @enabled == true
      end

      def configure!(endpoint:, api_token: nil)
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
          c.service_name = "buildkite-test-collector-ruby"
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
      rescue LoadError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled (missing gem): #{e.message}"
        @enabled = false
      rescue StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        @enabled = false
      end

      def in_test_span(name:, external_id: nil, attributes: {})
        return yield unless enabled?

        span_attributes = { EXECUTION_EXTERNAL_ID_ATTRIBUTE => external_id }
          .merge(attributes)
          .select { |_, value| !value.nil? }
        @tracer.in_span(name, attributes: span_attributes, kind: :internal) do |_span|
          yield
        end
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
    end
  end
end
