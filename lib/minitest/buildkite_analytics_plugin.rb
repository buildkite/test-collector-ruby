require_relative 'reporter'

module Minitest
  def self.plugin_buildkite_analytics_init(options)
    self.reporter << Minitest::Reporter.new(options[:io], options)
  end
end