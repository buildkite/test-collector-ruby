# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :example, :failure_reason, :failure_expanded

    # Left open by the around hook; Reporter finishes it once RSpec
    # settles the example's result.
    attr_accessor :otel_span, :otel_end_timestamp

    attr_reader :history
    attr_reader :tags
    attr_reader :location_prefix

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(example, history:, failure_reason: nil, failure_expanded: [], tags: nil, location_prefix: nil, external_id: nil, trace_id: nil)
      @example = example
      @history = history
      @failure_reason = failure_reason
      @failure_expanded = failure_expanded
      @tags = tags
      @location_prefix = location_prefix
      @external_id = external_id
      @trace_id = trace_id
    end

    def result
      case example.execution_result.status
      when :passed; "passed"
      when :failed; "failed"
      when :pending; "skipped"
      end
    end

    # Read at reporter time, when the result is final.
    def otel_result
      result
    end

    # What the span says about the test itself. The two OTel modes use the same
    # attributes; buildkite.execution.via is the sole synthesis opt-in.
    def otel_attributes
      attributes = {
        "buildkite.test.scope" => strip_invalid_utf8_chars(scope),
        "buildkite.test.name" => strip_invalid_utf8_chars(name),
        "test.case.name" => strip_invalid_utf8_chars(example.full_description),
        "test.suite.name" => strip_invalid_utf8_chars(scope),
        "code.file.path" => strip_invalid_utf8_chars(prepend_location_prefix(file_name)),
        "code.line.number" => source_line_number,
      }
      attributes["buildkite.execution.via"] = "otlp" if Buildkite::TestCollector.otel_only?
      attributes["buildkite.test.execution.external_id"] = external_id if external_id
      tags&.each do |key, value|
        attributes["buildkite.tag.#{key}"] = strip_invalid_utf8_chars(value.to_s)
      end
      attributes
    end

    def otel_failure_reason
      strip_invalid_utf8_chars(failure_reason) if failure_reason
    end

    def otel_exception_events
      (failure_expanded || []).filter_map do |failure|
        message = Array(failure[:expanded]).join("\n")
        stacktrace = Array(failure[:backtrace]).join("\n")
        attributes = {}
        attributes["exception.message"] = strip_invalid_utf8_chars(message) unless message.empty?
        attributes["exception.stacktrace"] = strip_invalid_utf8_chars(stacktrace) unless stacktrace.empty?
        attributes unless attributes.empty?
      end
    end

    private

    # Shared examples report the location of the shared block, so use the call
    # site instead, the same way file_name does.
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
