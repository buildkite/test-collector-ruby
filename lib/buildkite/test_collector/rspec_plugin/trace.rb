# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :failure_reason, :failure_expanded
    attr_writer :result
    attr_reader :history
    attr_reader :tags
    attr_reader :location_prefix

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(example, history:, failure_reason: nil, failure_expanded: [], tags: nil, location_prefix: nil)
      @history = history
      @failure_reason = failure_reason
      @failure_expanded = failure_expanded
      @tags = tags
      @location_prefix = location_prefix

      # Extract all data eagerly to allow GC of the test object
      @scope = example.example_group.metadata[:full_description]
      @name = example.description
      @location = example.location
      @id = strip_invalid_utf8_chars(example.id)
      @shared_group_inclusion_backtrace = example.metadata[:shared_group_inclusion_backtrace]
    end

    def result
      @result
    end

    private

    def scope
      @scope
    end

    def name
      @name
    end

    def location
      @location
    end

    def file_name
      @file_name ||= begin
        identifier_file_name = @id[FILE_PATH_REGEX]
        location_file_name = @location[FILE_PATH_REGEX]

        if identifier_file_name != location_file_name
          if shared_example?
            shared_example_call_location[FILE_PATH_REGEX]
          else
            "Unknown"
          end
        else
          identifier_file_name
        end
      end
    end

    def shared_example?
      !@shared_group_inclusion_backtrace.empty?
    end

    def shared_example_call_location
      @shared_group_inclusion_backtrace.last.inclusion_location
    end
  end
end
