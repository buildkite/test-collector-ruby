# frozen_string_literal: true

module Buildkite::TestCollector::CucumberPlugin
  class Trace < Buildkite::TestCollector::Trace
    attr_accessor :scenario, :failure_reason, :failure_expanded
    attr_reader :history, :tags, :location_prefix

    FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

    def initialize(scenario, history:, failure_reason: nil, failure_expanded: [], tags: nil, location_prefix: nil)
      @scenario         = scenario
      @history          = history
      @failure_reason   = failure_reason
      @failure_expanded = failure_expanded
      @tags             = tags
      @location_prefix  = location_prefix
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

    private

    def gherkin_parser
      @gherkin_parser ||= Gherkin::Parser.new
    end

    def document
      @document ||= gherkin_parser.parse(File.read(file_name))
    end

    def scope
      document.feature.name
    end

    def name
      scenario.name
    end

    def location
      scenario.location&.to_s
    end

    def file_name
      @file_name ||= location&.to_s[FILE_PATH_REGEX]
    end
  end
end
