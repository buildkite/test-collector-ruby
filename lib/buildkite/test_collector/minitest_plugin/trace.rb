# frozen_string_literal: true

module Buildkite::TestCollector::MinitestPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :example
    attr_writer :failure_reason, :failure_expanded
    attr_reader :history
    attr_reader :location_prefix
    attr_reader :tags

    RESULT_CODES = {
      '.' => 'passed',
      'F' => 'failed',
      'E' => 'failed',
      'S' => 'pending',
    }

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(example, history:, tags: nil, trace: nil, location_prefix: nil)
      @example = example
      @history = history
      @tags = tags
      @location_prefix = location_prefix
    end

    def result
      RESULT_CODES[example.result_code]
    end

    def source_location
      @source_location ||= example.method(example.name).source_location
    end

    private

    def scope
      example.class.name
    end

    def name
      example.name
    end

    def location
      if file_name
        "#{file_name}:#{line_number}"
      end
    end

    def file_name
      @file_name ||= File.join('./', source_location[0].sub(/\A#{project_dir}/, ""))
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
        messages = messages[1..-1] if index.zero?

        {
          expanded: messages,
          backtrace: failure.backtrace
        }
      end
    end
  end
end
