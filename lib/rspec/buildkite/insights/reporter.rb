module RSpec::Buildkite::Insights
  class Reporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending

    def initialize(output)
      @output = output
    end

    def handle_example(notification)
      example = notification.example
      trace = RSpec::Buildkite::Insights.uploader.traces.find do |trace|
        compare_example(example, trace.example)
      end

      if trace
        trace.example = example
        RSpec::Buildkite::Insights.session.write_result(trace)
      end
    end

    alias_method :example_passed, :handle_example
    alias_method :example_failed, :handle_example
    alias_method :example_pending, :handle_example

    private

    def compare_example(example, another_example)
      example.file_path == another_example.file_path &&
      example.full_description == another_example.full_description &&
      example.location == another_example.location
    end
  end
end
