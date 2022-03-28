puts "loading minitest reporter"

module Minitest
  class Reporter
    def initialize(io, options)
      @io = io
      @options = options
    end
   
    def record(result)
      # FIXME: id can be result.name for the moment
      # but later we need to replicate the RSpec example.id in reporter.rb
      id = "#{result.to_s} [#{result.source_location.join(':')}]"
      trace = RSpec::Buildkite::Analytics.uploader.traces.find do |trace|
        example.id == trace.example.id
      end

      if trace
        trace.example = example
        trace.failure_reason, trace.failure_expanded = failure_info(notification) if example.execution_result.status == :failed
        RSpec::Buildkite::Analytics.session&.write_result(trace)
      else
        # FIXME: we can't seem to find any traces !!!
        print 'F'
      end
    end



    def report
    end
  end
end