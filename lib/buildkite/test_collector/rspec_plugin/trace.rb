# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :example, :failure_reason, :failure_expanded
    # The exception that failed the test, recorded onto the OpenTelemetry span
    # when OTLP is the only upload method.
    attr_accessor :otel_exception
    attr_reader :history
    attr_reader :tags
    attr_reader :location_prefix

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(example, history:, failure_reason: nil, failure_expanded: [], tags: nil, location_prefix: nil, external_id: nil, trace_id: nil, otel_only: false)
      @example = example
      @history = history
      @failure_reason = failure_reason
      @failure_expanded = failure_expanded
      @tags = tags
      @location_prefix = location_prefix
      @external_id = external_id
      @trace_id = trace_id
      @otel_only = otel_only
    end

    def result
      case example.execution_result.status
      when :passed; "passed"
      when :failed; "failed"
      when :pending; "skipped"
      end
    end

    # RSpec settles an example's result after our around hook returns, so derive
    # it the way RSpec itself does: an exception means failed, a pending message
    # means skipped, anything else passed.
    def otel_result
      if example.exception
        "failed"
      elsif example.execution_result.pending_message
        "skipped"
      else
        "passed"
      end
    end

    # What the span says about the test itself. Same file path as the execution
    # upload, so the two agree. When OTLP is the only upload method, the span
    # instead carries everything a JSON upload would have said.
    def otel_attributes
      return otel_only_attributes if @otel_only

      attributes = {
        "test.case.name" => example.full_description,
        "test.suite.name" => scope,
        "code.file.path" => strip_invalid_utf8_chars(prepend_location_prefix(file_name)),
        "code.line.number" => source_line_number,
      }
      attributes["buildkite.test.execution.external_id"] = external_id if external_id
      attributes
    end

    private

    # The full execution details, mirroring the fields of a JSON upload.
    # `execution.via` tells the ingestion pipeline that no JSON is coming and
    # it should synthesize the execution from this span alone.
    def otel_only_attributes
      file_path = strip_invalid_utf8_chars(prepend_location_prefix(file_name))
      attributes = {
        "execution.via" => "otlp",
        "test.scope" => strip_invalid_utf8_chars(scope),
        "test.name" => strip_invalid_utf8_chars(name),
        "buildkite.test.location" => strip_invalid_utf8_chars(prepend_location_prefix(location)),
        "buildkite.test.file_name" => file_path,
        "test.suite.name" => strip_invalid_utf8_chars(scope),
        "test.case.name" => strip_invalid_utf8_chars(example.full_description),
        "code.file.path" => file_path,
        "code.line.number" => source_line_number,
        "buildkite.test.result" => otel_result,
      }

      if failure_reason
        attributes["buildkite.test.failure_reason"] = strip_invalid_utf8_chars(failure_reason)
      end
      if failure_expanded && !failure_expanded.empty?
        attributes["buildkite.test.failure_expanded"] = JSON.generate(strip_invalid_utf8_chars(failure_expanded))
      end

      # Tags set through Buildkite::TestCollector.tag_execution become plain
      # span attributes, which the server turns back into execution tags.
      tags&.each do |key, value|
        attributes[key.to_s] = strip_invalid_utf8_chars(value.to_s)
      end

      attributes.reject { |_, value| value.nil? }
    end

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
