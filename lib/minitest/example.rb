# frozen_string_literal: true

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
      location, line_number = @result.source_location

      "#{File.join('./', location.delete_prefix(project_dir))}:#{line_number}"
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

    def failure_reason
      @result.failure.message
    end

    def failure_expanded
      @result.failures.map do |failure|
        {
          expanded: failure.message,
          backtrace: failure.backtrace,
        }
      end
    end

    private

    def project_dir
      if defined?(Rails) && Rails.respond_to?(:root)
        Rails.root
      else
        Dir.getwd
      end
    end
  end
end