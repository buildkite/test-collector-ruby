require "time"

module RSpec::Buildkite::Analytics
  class Reporter

    attr_reader :output

    def initialize(output)
      @output = output
    end

    def handle_example(notification)
      example = notification.example
      trace = RSpec::Buildkite::Analytics.uploader.traces[example.id]

      if trace
        trace.example = example
        trace.failure_reason, trace.failure_expanded = failure_info(notification) if example.execution_result.status == :failed
        RSpec::Buildkite::Analytics.session&.write_result(trace)
      end
    end

    def dump_summary(notification)
      if RSpec::Buildkite::Analytics.session.present?
        examples_count = {
          examples: notification.examples.count,
          failed: notification.failed_examples.count,
          pending: notification.pending_examples.count,
          errors_outside_examples: notification.errors_outside_of_examples_count
        }

        RSpec::Buildkite::Analytics.session.close(examples_count)

        # Write the debug file, if debug mode is enabled
        if RSpec::Buildkite::Analytics.debug_enabled
          filename = "#{RSpec::Buildkite::Analytics.debug_filepath}/bk-analytics-#{Time.now.strftime("%F-%R:%S")}-#{ENV["BUILDKITE_JOB_ID"]}.log.gz"

          File.open(filename, "wb") do |f|
            gz = Zlib::GzipWriter.new(f)
            gz.puts(RSpec::Buildkite::Analytics.session.logger.to_array)
            gz.close
          end
        end
      end
    end

    alias_method :example_passed, :handle_example
    alias_method :example_failed, :handle_example
    alias_method :example_pending, :handle_example

    private

    MULTIPLE_ERRORS = [
      RSpec::Expectations::MultipleExpectationsNotMetError,
      RSpec::Core::MultipleExceptionError
    ]

    def failure_info(notification)
      failure_expanded = []

      if RSpec::Buildkite::Analytics::Reporter::MULTIPLE_ERRORS.include?(notification.exception.class)
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
