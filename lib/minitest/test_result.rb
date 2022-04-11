# frozen_string_literal: true

module Minitest
  class TestResult
    RESULT_CODES = {
      '.' => 'passed',
      'F' => 'failed',
      'E' => 'failed',
      'S' => 'pending',
    }

    def initialize(result)
      @result = result
    end

    def result_state
      case @result.result_code
      when "."; "passed"
      when "F"; "failed"
      when "E"; "failed"
      when "S"; "skipped"
      end
    end

    def id
      location, line_number = @result.source_location

      "#{File.join('./', location.delete_prefix(project_dir))}:#{line_number}"
    end
    alias_method :location, :id
    alias_method :identifier, :id

    # In Rspec this would be the describe/context, but minitest does not support this natively
    # So instead we provide the class name (as context)
    def scope
      @result.class_name
    end

    def name
      @result.name
    end

    def shared_example?
      false
    end

    def shared_example_last_backtrace_location
      ''
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