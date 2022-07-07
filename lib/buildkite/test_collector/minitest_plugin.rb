# frozen_string_literal: true

# Minitest finds this file before setup code
require_relative "tracer"

require_relative "minitest_plugin/reporter"
require_relative "minitest_plugin/trace"

module Buildkite::TestCollector::MinitestPlugin
  def before_setup
    super
    tracer = Buildkite::TestCollector::Tracer.new
    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
  end

  def after_teardown
    tracer = Thread.current[:_buildkite_tracer]
    if !tracer.nil?
      Thread.current[:_buildkite_tracer] = nil
      tracer.finalize

      trace = Buildkite::TestCollector::MinitestPlugin::Trace.new(self, history: tracer.history)
      Buildkite::TestCollector.uploader.traces[trace.source_location] = trace
    end

    super
  end
end
