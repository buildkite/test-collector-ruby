require_relative 'reporter'
require_relative 'example'

module Minitest
  def self.plugin_buildkite_analytics_init(options)
    self.reporter << Minitest::BuildkiteAnalyticsReporter.new(options[:io], options)
  end
end