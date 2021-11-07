require "time"

module RSpec::Buildkite::Analytics
  class Reporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending, :dump_summary

    attr_reader :output

    def initialize(output)
      @output = output
    end

    def handle_example(notification)
      example = notification.example
      trace = RSpec::Buildkite::Analytics.uploader.traces.find do |trace|
        example.id == trace.example.id
      end

      if trace
        trace.example = example
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
  end
end
