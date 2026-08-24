# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Reporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending, :dump_summary

    attr_reader :output

    def initialize(output)
      unless Buildkite::TestCollector.otel_only?
        Buildkite::TestCollector.session = Buildkite::TestCollector::Session.new
      end
      @output = output
    end

    def handle_example(notification)
      example = notification.example
      trace = Buildkite::TestCollector.uploader.traces[example.id]

      if trace
        trace.example = example
        if example.execution_result.status == :failed
          begin
            trace.failure_reason, trace.failure_expanded = failure_info(notification)
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not describe test failure: #{e.class}: #{e.message}"
          end
        end

        finish_otel_span(trace)

        unless Buildkite::TestCollector.otel_only?
          Buildkite::TestCollector.session.add_example_to_send_queue(example.id)
        end
      end
    ensure
      if Buildkite::TestCollector.otel_only?
        Buildkite::TestCollector.uploader.traces.delete(example&.id)
      end
    end

    def dump_summary(_notification)
      return if Buildkite::TestCollector.otel_only?

      Buildkite::TestCollector.session.send_remaining_data
      Buildkite::TestCollector.session.close
    end

    alias_method :example_passed, :handle_example
    alias_method :example_failed, :handle_example
    alias_method :example_pending, :handle_example

    private

    def finish_otel_span(trace)
      return unless trace.otel_span

      span_duration = Buildkite::TestCollector::OTel.finish_test_span(
        trace.otel_span,
        test: trace,
        end_timestamp: trace.otel_end_timestamp,
      )
      trace.otel_span = nil

      # Mirror the span's timing onto the JSON history so the two never
      # disagree; skip if a clock step made the duration negative.
      if span_duration && span_duration >= 0 && trace.history[:start_at]
        trace.history[:duration] = span_duration
        trace.history[:end_at] = trace.history[:start_at] + span_duration
      end
    rescue StandardError => e
      warn "[buildkite-test_collector] Could not finish the OpenTelemetry test span: #{e.class}: #{e.message}"
    end

    MULTIPLE_ERRORS = [
      RSpec::Expectations::MultipleExpectationsNotMetError,
      RSpec::Core::MultipleExceptionError
    ]

    def blank?(string)
      string.nil? || string.strip.empty?
    end

    def failure_info(notification)
      failure_expanded = []

      if Buildkite::TestCollector::RSpecPlugin::Reporter::MULTIPLE_ERRORS.include?(notification.exception.class)
        failure_reason = notification.exception.summary
        notification.exception.all_exceptions.each do |exception|
          # an example with multiple failures doesn't give us a
          # separate message lines and backtrace object to send, so
          # I've reached into RSpec internals and duplicated the
          # construction of these
          message_lines = RSpec::Core::Formatters::ExceptionPresenter.new(exception, notification.example).colorized_message_lines

          failure_expanded << {
            expanded: format_message_lines(message_lines),
            backtrace:  RSpec.configuration.backtrace_formatter.format_backtrace(exception.backtrace)
          }
        end
      else
        message_lines = notification.colorized_message_lines
        failure_reason = strip_diff_colors(message_lines.shift)

        failure_expanded << {
          expanded:  format_message_lines(message_lines),
          backtrace: notification.formatted_backtrace
        }
      end

      return failure_reason, failure_expanded
    end

    def format_message_lines(message_lines)
      message_lines.map! { |l| strip_diff_colors(l) }
      # the first line is sometimes blank, depending on the error reported
      message_lines.shift if blank?(message_lines.first)
      # the last line is sometimes blank, depending on the error reported
      message_lines.pop if blank?(message_lines.last)
      message_lines
    end

    def strip_diff_colors(string)
      string.gsub(/\e\[([;\d]+)?m/, '')
    end
  end
end
