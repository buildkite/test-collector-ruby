# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Reporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending, :dump_summary

    attr_reader :output

    def initialize(output)
      Buildkite::TestCollector.session = Buildkite::TestCollector::Session.new
      @output = output
    end

    def handle_example(notification)
      example = notification.example
      trace = Buildkite::TestCollector.uploader.traces[example.id]

      if trace
        trace.example = example
        if example.execution_result.status == :failed
          trace.failure_reason, trace.failure_expanded = failure_info(notification)
        end
        Buildkite::TestCollector.session.add_example_to_send_queue(example.id)
      end
    end

    def handle_failed_example(notification)
      $stdout.puts "🤡 start of handle_failed_example"
      $stdout.puts Thread.current
      example = notification.example
      trace = Buildkite::TestCollector.uploader.traces[example.id]
      $stdout.puts "🤡 example id: #{example.id}"

      if trace
        $stdout.puts "🤡 found trace"
        trace.example = example
        $stdout.puts "🤡 execution result: #{example.execution_result}"
        if example.execution_result.status == :failed
          trace.failure_reason, trace.failure_expanded = failure_info(notification)
        end
        $stdout.puts "🤡 adding example to queue"
        Buildkite::TestCollector.session.add_example_to_send_queue(example.id)
      end
      $stdout.puts "🤡 end of handle_failed_example"
    end

    def dump_summary(_notification)
      Buildkite::TestCollector.session.send_remaining_data
      Buildkite::TestCollector.session.close
    end

    alias_method :example_passed, :handle_example
    alias_method :example_failed, :handle_failed_example
    alias_method :example_pending, :handle_example

    private

    MULTIPLE_ERRORS = [
      RSpec::Expectations::MultipleExpectationsNotMetError,
      RSpec::Core::MultipleExceptionError
    ]

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
      message_lines.shift if message_lines.first.blank?
      # the last line is sometimes blank, depending on the error reported
      message_lines.pop if message_lines.last.blank?
      message_lines
    end

    def strip_diff_colors(string)
      string.gsub(/\e\[([;\d]+)?m/, '')
    end
  end
end
