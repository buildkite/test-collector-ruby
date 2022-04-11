module RSpec::Buildkite::Analytics
  class TestResult
    def initialize(example)
      @example = example
    end

    def result_state
      case @example.execution_result.status
      when :passed; "passed"
      when :failed; "failed"
      when :pending; "skipped"
      end
    end

    def id
      @example.id
    end
    alias_method :location, :id
    alias_method :identifier, :id

    def scope
      @example.example_group.metadata[:full_description]
    end

    def name
      @example.description
    end

    def shared_example?
      @example.metadata[:shared_group_inclusion_backtrace].any?
    end

    def shared_example_last_backtrace_location
      @example.metadata[:shared_group_inclusion_backtrace].last.inclusion_location
    end
  end
end
 