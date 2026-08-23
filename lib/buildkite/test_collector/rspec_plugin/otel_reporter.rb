# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  # Finishes each example's OpenTelemetry test span from RSpec's reporter
  # notifications, which fire after every around hook has unwound. By then
  # RSpec has settled the example's final result, so the span's classification
  # simply reads that verdict: an around hook that raises after example.run
  # comes out failed, an acknowledged-pending example (pending plus a
  # deliberate raise) skipped, and a pending-but-fixed example failed.
  #
  # The span still times the example itself, not the reporting that follows:
  # the around hook captured the end timestamp at unwind, and the span is
  # finished here with that timestamp.
  #
  # Registered before Reporter, so the span (and the history's duration,
  # which mirrors it) is settled before the example is queued for upload.
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

      # When there is a span, report what it timed as the execution's duration
      # too, so the two never disagree. `end_at` moves with it, so the history
      # still describes itself and its children still sit inside it. The
      # captured end is a realtime reading, so a clock step during the example
      # could make it precede the span's start; keep the tracer's own timing
      # rather than upload a negative duration.
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
