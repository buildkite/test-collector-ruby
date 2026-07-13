# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :example, :failure_reason, :failure_expanded
    attr_reader :history
    attr_reader :tags
    attr_reader :location_prefix

    # example.id looks like "./spec/foo_spec.rb[1:2]" - strip the trailing
    # example index suffix to get the file path.
    ID_INDEX_SUFFIX_REGEX = /\[[\d:]+\]\z/

    # example.location looks like "./spec/foo_spec.rb:42" - strip the
    # trailing line number to get the file path.
    LOCATION_LINE_SUFFIX_REGEX = /:\d+\z/

    # shared_example_call_location is a raw backtrace line, e.g.
    # "./spec/foo_spec.rb:12:in `block (2 levels) in <top (required)>'" -
    # strip the trailing line number and frame label to get the file path.
    BACKTRACE_LINE_SUFFIX_REGEX = /:\d+:in\b.*\z/

    def initialize(example, history:, failure_reason: nil, failure_expanded: [], tags: nil, location_prefix: nil)
      @example = example
      @history = history
      @failure_reason = failure_reason
      @failure_expanded = failure_expanded
      @tags = tags
      @location_prefix = location_prefix
    end

    def result
      case example.execution_result.status
      when :passed; "passed"
      when :failed; "failed"
      when :pending; "skipped"
      end
    end

    private

    def scope
      example.example_group.metadata[:full_description]
    end

    def name
      example.description
    end

    def location
      example.location
    end

    def file_name
      @file_name ||= begin
        identifier_file_name = strip_invalid_utf8_chars(example.id).sub(ID_INDEX_SUFFIX_REGEX, "")
        location_file_name = example.location.sub(LOCATION_LINE_SUFFIX_REGEX, "")

        if identifier_file_name != location_file_name
          # If the identifier and location files are not the same, we assume
          # that the test was run as part of a shared example. If this isn't the
          # case, then there's something we haven't accounted for
          if shared_example?
            # Taking the last frame in this backtrace will give us the original
            # entry point for the shared example
            shared_example_call_location.sub(BACKTRACE_LINE_SUFFIX_REGEX, "")
          else
            "Unknown"
          end
        else
          identifier_file_name
        end
      end
    end

    def shared_example?
      !example.metadata[:shared_group_inclusion_backtrace].empty?
    end

    def shared_example_call_location
      example.metadata[:shared_group_inclusion_backtrace].last.inclusion_location
    end
  end
end
