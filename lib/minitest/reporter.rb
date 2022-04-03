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

    private

    # In Our BuildkiteMiniTestPlugin#before_setup and BuildkiteMiniTestPlugin#before_teardown methods we get access to a
    # Minitest::Test. In our reporter we get access to a result object, the result object has the source location of
    # the test, but the MiniTest::Test does not, and we need to match them up, this method returns the source location
    # for both the test and the result objects
    def source_location(result_or_test)
      if result_or_test.respond_to?(:source_location)
        result_or_test.source_location.join(':')
      else
        result_or_test.class_name.constantize.instance_method(result_or_test.name).source_location.join(':')
      end
    end
  end
end