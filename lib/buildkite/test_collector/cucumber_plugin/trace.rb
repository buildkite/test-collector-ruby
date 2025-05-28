# frozen_string_literal: true

module Buildkite::TestCollector::CucumberPlugin
  class Trace
    attr_accessor :scenario, :failure_reason, :failure_expanded
    attr_reader :history, :tags

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(scenario, history:, failure_reason: nil, failure_expanded: [], tags: nil)
      @scenario         = scenario
      @history          = history
      @failure_reason   = failure_reason
      @failure_expanded = failure_expanded
      @tags             = tags
    end

    def result
      if scenario.passed?
        'passed'
      elsif scenario.failed?
        'failed'
      else
        'skipped'
      end
    end

    def as_hash
      parser = Gherkin::Parser.new
      document = parser.parse(File.read(file_name))
      feature_name = document.feature.name

      strip_invalid_utf8_chars(
        scope:          feature_name,
        name:           scenario.name,
        location:       scenario.location&.to_s,
        file_name:      file_name,
        result:         result,
        failure_reason: failure_reason,
        failure_expanded: failure_expanded,
        history:        history,
        tags:           tags,
      ).select { |_, v| !v.nil? }
    end

    private

    def file_name
      @file_name ||= scenario.location&.to_s[FILE_PATH_REGEX]
    end

    def strip_invalid_utf8_chars(object)
      case object
      when Hash
        object.transform_values { |v| strip_invalid_utf8_chars(v) }
      when Array
        object.map { |v| strip_invalid_utf8_chars(v) }
      when String
        object.encode('UTF-8', invalid: :replace, undef: :replace)
      else
        object
      end
    end
  end
end
