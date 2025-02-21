# frozen_string_literal: true

# Minitest finds this file before setup code
require_relative "tracer"

require_relative "minitest_plugin/reporter"
require_relative "minitest_plugin/trace"

module Buildkite::TestCollector::MinitestPlugin
  def before_setup
    super

    tracer = Buildkite::TestCollector::Tracer.new(
      min_duration: Buildkite::TestCollector.trace_min_duration,
    )

    tags = {}

    # _buildkite prefix reduces chance of collisions in this almost-global (per-fiber) namespace.
    Thread.current[:_buildkite_tracer] = tracer
    Thread.current[:_buildkite_tags] = tags
  end

  def after_teardown
    tracer = Thread.current[:_buildkite_tracer]
    tags = Thread.current[:_buildkite_tags]

    Thread.current[:_buildkite_tracer] = nil
    Thread.current[:_buildkite_tags] = nil

    if !tracer.nil?
      tracer.finalize

      trace = Buildkite::TestCollector::MinitestPlugin::Trace.new(
        self,
        history: tracer.history,
        tags: tags,
      )

      Buildkite::TestCollector.uploader.traces[trace.source_location] = trace
    end

    super
  end
end
