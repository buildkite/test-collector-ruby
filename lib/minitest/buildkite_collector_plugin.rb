module Minitest
  def self.plugin_buildkite_collector_init(options)
    if Buildkite::Collector.respond_to?(:uploader)
      self.reporter << Buildkite::Collector::MinitestPlugin::Reporter.new(options[:io], options)
    end
  end
end
