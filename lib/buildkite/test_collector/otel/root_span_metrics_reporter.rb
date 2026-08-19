# frozen_string_literal: true

module Buildkite
  module TestCollector
    module OTel
      # BatchSpanProcessor reports queue overflow only through a no-op metrics
      # reporter by default. Root loss is too important to leave silent, so warn
      # once if the reserved queue drops any spans.
      class RootSpanMetricsReporter
        def initialize
          @mutex = Mutex.new
          @warned = false
        end

        def add_to_counter(metric, increment: 1, labels: {})
          return unless metric == "otel.bsp.dropped_spans"

          should_warn = @mutex.synchronize do
            next false if @warned

            @warned = true
          end
          return unless should_warn

          reason = labels["reason"]
          warn(
            "[buildkite-test_collector] OpenTelemetry dropped #{increment} " \
            "test.execution span(s)#{" (#{reason})" if reason}; some test executions may be missing"
          )
        end

        def record_value(_metric, value:, labels: {}); end

        def observe_value(_metric, value:, labels: {}); end
      end
      private_constant :RootSpanMetricsReporter
    end
  end
end
