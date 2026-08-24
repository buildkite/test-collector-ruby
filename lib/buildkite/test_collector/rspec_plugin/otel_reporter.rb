# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  # Finishes each example's test span once RSpec's reporter notifications
  # fire, after every around hook has unwound and the result is settled.
  # Registered before Reporter, so the span settles before upload.
  class OTelReporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending

    def initialize(_output)
    end

    def handle_example(notification)
      example = notification.example
      trace = Buildkite::TestCollector.uploader.traces[example.id]
      return unless trace&.otel_span

      span_duration = Buildkite::TestCollector::OTel.finish_test_span(
        trace.otel_span,
        test: trace,
        end_timestamp: trace.otel_end_timestamp,
      )
      trace.otel_span = nil

      # Mirror the span's timing onto the history so the two never disagree;
      # skip if a clock step made the duration negative.
      if span_duration && span_duration >= 0
        trace.history[:duration] = span_duration
        trace.history[:end_at] = trace.history[:start_at] + span_duration
      end
    rescue StandardError => e
      warn "[buildkite-test_collector] Could not finish the OpenTelemetry test span: #{e.class}: #{e.message}"
    end

    alias_method :example_passed, :handle_example
    alias_method :example_failed, :handle_example
    alias_method :example_pending, :handle_example
  end
end
