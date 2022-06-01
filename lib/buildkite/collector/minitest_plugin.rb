# frozen_string_literal: true

require_relative "minitest_plugin/reporter"
require_relative "minitest_plugin/trace"

module Buildkite::Collector::MinitestPlugin
  def before_setup
    super
    tracer = Buildkite::Collector::Tracer.new
    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
  end

  def before_teardown
    super

    tracer = Thread.current[:_buildkite_tracer]
    if !tracer.nil?
      Thread.current[:_buildkite_tracer] = nil
      tracer.finalize

      trace = Buildkite::Collector::MinitestPlugin::Trace.new(self, history: tracer.history)
      Buildkite::Collector.uploader.traces[trace.source_location] = trace
    end
  end
end
