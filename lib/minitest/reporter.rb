puts "loading minitest reporter"

module Minitest
  class BuildkiteAnalyticsReporter < Minitest::StatisticsReporter
    def initialize(io, options)
      super
      @io = io
      @options = options
    end
   
    def record(result)
      super
      # FIXME: RSpec has the relative path from the current project folder
      # so we may need to update the path to be relative (minitests path is absolute)
      # Rspec looks like: "./spec/features/budgets_spec.rb[1:1]"
      id = "#{result.location} [#{source_location(result)}]"

      trace = RSpec::Buildkite::Analytics.uploader.traces.find do |trace|
        trace_id = "#{trace.example.location} [#{source_location(result)}]"
        id == trace_id
      end

      if trace
        trace.example = MiniTest::Example.new(result)
        if trace.example.execution_result.status == :failed
          trace.failure_reason = trace.example.failure_reason
          trace.failure_expanded = trace.example.failure_expanded
        end
        RSpec::Buildkite::Analytics.session&.write_result(trace)
      else
        # FIXME: some traces are missing
        print 'F'
      end
    end



    def report
      super

      if RSpec::Buildkite::Analytics.session.present?
        examples_count = {
          examples: count,
          failed: failures,
          pending: skips,
          errors_outside_examples: 0,
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

    private

    # trace.example is a MiniTest::Test where as result is a MiniTest::Result
    # trace.example does not have a method to get the source_location
    # so we can have some common logic which works for both
    # FIXME: seems there may be some meta programming so this isn't always possible?
    def source_location(result_or_test)
      if result_or_test.respond_to?(:source_location)
        result_or_test.source_location.join(':')
      else
        result_or_test.class_name.constantize.instance_method(result_or_test.name).source_location.join(':')
      end
    rescue
      # FIXME: remove this once we're in the clear :)
      binding.irb
    end
  end
end