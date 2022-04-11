# frozen_string_literal: true

module Minitest
  class BuildkiteAnalyticsReporter < Minitest::StatisticsReporter
    def initialize(io, options)
      super
      @io = io
      @options = options
    end
   
    def record(result)
      super

      trace = RSpec::Buildkite::Analytics.uploader.traces[result.source_location]

      if trace
        trace.test_result = MiniTest::TestResult.new(result)
        if trace.test_result.result_state == 'failed'
          trace.failure_reason = trace.test_result.failure_reason
          trace.failure_expanded = trace.test_result.failure_expanded
        end
        RSpec::Buildkite::Analytics.session&.write_result(trace)
      end
    end

    def report
      super

      if RSpec::Buildkite::Analytics.session.present?
        examples_count = {
          examples: count,
          failed: failures,
          pending: skips,
          errors_outside_examples: 0, # Minitest does not report this
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
  end
end