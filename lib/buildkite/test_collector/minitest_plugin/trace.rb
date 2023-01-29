# frozen_string_literal: true

module Buildkite::TestCollector::MinitestPlugin
  class Trace
    attr_accessor :example
    attr_writer :failure_reason, :failure_expanded
    attr_reader :id, :history

    RESULT_CODES = {
      '.' => 'passed',
      'F' => 'failed',
      'E' => 'failed',
      'S' => 'pending',
    }

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(example, history:)
      @id = SecureRandom.uuid
      @example = example
      @history = history
    end

    def result
      RESULT_CODES[example.result_code]
    end

    def source_location
      @source_location ||= example.method(example.name).source_location
    end

    def as_hash
      strip_invalid_utf8_chars(
        id: id,
        scope: example.class.name,
        name: example.name,
        identifier: identifier,
        location: location,
        file_name: file_name,
        result: result,
        failure_reason: failure_reason,
        failure_expanded: failure_expanded,
        history: history,
      ).with_indifferent_access.compact
    end

    private

    def location
      if file_name
        "#{file_name}:#{line_number}"
      end
    end
    alias_method :identifier, :location

    def file_name
      @file_name ||= File.join('./', source_location[0].delete_prefix(project_dir))
    end

    def line_number
      @line_number ||= source_location[1]
    end

    def project_dir
      if defined?(Rails) && Rails.respond_to?(:root)
        Rails.root.to_s
      else
        Dir.getwd
      end
    end

    def failure_reason
      @failure_reason ||= strip_invalid_utf8_chars(example.failure&.message)&.split("\n")&.first
    end

    def failure_expanded
      @failure_expanded ||= example.failures.map.with_index do |failure, index|
        # remove the first line of message from the first failure
        # to avoid duplicate line in Test Analytics UI
        messages = strip_invalid_utf8_chars(failure.message).split("\n")
        messages = messages[1..] if index.zero?

        {
          expanded: messages,
          backtrace: failure.backtrace
        }
      end
    end

    def strip_invalid_utf8_chars(object)
      if object.is_a?(Hash)
        Hash[object.map { |key, value| [key, strip_invalid_utf8_chars(value)] }]
      elsif object.is_a?(Array)
        object.map { |value| strip_invalid_utf8_chars(value) }
      elsif object.is_a?(String)
        object.encode('UTF-8', :invalid => :replace, :undef => :replace)
      else
        object
      end
    end
  end
end
