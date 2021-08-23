module RSpec::Buildkite::Analytics
  class Reporter
    RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending

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

    alias_method :example_passed, :handle_example
    alias_method :example_failed, :handle_example
    alias_method :example_pending, :handle_example
  end
end
