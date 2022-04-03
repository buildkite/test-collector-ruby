# frozen_string_literal: true

require_relative 'reporter'
require_relative 'example'

module Minitest
  def self.plugin_buildkite_analytics_init(options)
    if RSpec::Buildkite::Analytics.respond_to?(:uploader)
      self.reporter << Minitest::BuildkiteAnalyticsReporter.new(options[:io], options)
    end
  end
end