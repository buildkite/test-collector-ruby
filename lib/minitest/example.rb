module Minitest
  class Example
    RESULT_CODES = {
      '.' => :passed,
      'F' => :failed,
      'E' => :failed,
      'S' => :pending,
    }

    def initialize(result)
      @result = result
    end

    def id
      @result.source_location.join(':')
    end

    alias_method :location, :id

    def execution_result
      Struct.new(:status).new(RESULT_CODES[@result.result_code])
    end

    def metadata
      { shared_group_inclusion_backtrace: [] }
    end

    # In Rspec this would be the describe/context, but minitest does not support this natively
    # So instead we provide the class name (as context)
    def example_group
      Struct.new(:metadata).new(full_description: @result.class_name)
    end

    def description
      @result.name
    end
  end
end