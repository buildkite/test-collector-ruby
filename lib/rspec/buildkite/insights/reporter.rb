module RSpec::Buildkite::Insights
  class Reporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending

    def initialize(output)
      @output = output
    end

    def example_passed(notification)
      example = notification.example
      trace = $__buildkite__uploader.traces.find {|trace| example == trace.example }
      trace.example = example

      $__buildkite__session.write_result(trace)
    end

    def example_failed(notification)
      example = notification.example
      trace = $__buildkite__uploader.traces.find {|trace| example == trace.example }
      trace.example = example

      $__buildkite__session.write_result(trace)
    end

    def example_pending(notification)
      example = notification.example
      trace = $__buildkite__uploader.traces.find {|trace| example == trace.example }
      trace.example = example

      $__buildkite__session.write_result(trace)
    end
  end
end
