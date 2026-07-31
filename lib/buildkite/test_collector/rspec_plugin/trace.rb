# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :example, :failure_reason, :failure_expanded
    attr_reader :history
    attr_reader :tags
    attr_reader :location_prefix
    attr_reader :otel_span

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(example, history:, failure_reason: nil, failure_expanded: [], tags: nil, location_prefix: nil, external_id: nil, otel_span: nil)
      @example = example
      @history = history
      @failure_reason = failure_reason
      @failure_expanded = failure_expanded
      @tags = tags
      @location_prefix = location_prefix
      @external_id = external_id
      @otel_span = otel_span
    end

    def result
      case example.execution_result.status
      when :passed; "passed"
      when :failed; "failed"
      when :pending; "skipped"
      end
    end

    def otel_attributes
      {
        "test.case.name" => example.full_description,
        "test.suite.name" => example.example_group.metadata[:full_description],
        "code.file.path" => strip_invalid_utf8_chars(prepend_location_prefix(file_name)),
        "code.line.number" => source_line_number,
        "buildkite.test.case.id" => example.id,
        "buildkite.test.runner.name" => "rspec",
        "buildkite.test.runner.version" => RSpec::Core::Version::STRING,
      }
    end

    private

    def source_line_number
      source = shared_example? ? shared_example_call_location : example.location
      source[/:(\d+)\z/, 1]&.to_i
    end

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
        identifier_file_name = strip_invalid_utf8_chars(example.id)[FILE_PATH_REGEX]
        location_file_name = example.location[FILE_PATH_REGEX]

        if identifier_file_name != location_file_name
          # If the identifier and location files are not the same, we assume
          # that the test was run as part of a shared example. If this isn't the
          # case, then there's something we haven't accounted for
          if shared_example?
            # Taking the last frame in this backtrace will give us the original
            # entry point for the shared example
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
      !example.metadata[:shared_group_inclusion_backtrace].empty?
    end

    def shared_example_call_location
      example.metadata[:shared_group_inclusion_backtrace].last.inclusion_location
    end
  end
end
