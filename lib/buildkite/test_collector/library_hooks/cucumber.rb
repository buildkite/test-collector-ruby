# frozen_string_literal: true

require 'cucumber'

require_relative '../cucumber_plugin/trace'

# Use Buildkite's uploader for Cucumber as well
Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

# -------------------------------------------------
# Hooks
# -------------------------------------------------

Before do |scenario|
  tracer = Buildkite::TestCollector::Tracer.new(
    min_duration: Buildkite::TestCollector.trace_min_duration,
  )

  tags = {}

  # _buildkite prefix reduces chance of collisions in this almost-global (per-fiber) namespace.
  Thread.current[:_buildkite_tracer] = tracer
  Thread.current[:_buildkite_tags] = tags
end

After do |scenario|
  tracer = Thread.current[:_buildkite_tracer]
  tags   = Thread.current[:_buildkite_tags]

  Thread.current[:_buildkite_tracer] = nil
  Thread.current[:_buildkite_tags]   = nil

  if tracer
    tracer.finalize

    failure_reason   = nil
    failure_expanded = []

    if scenario.failed?
      exception = scenario.exception
      if exception
        failure_reason = exception.message
        failure_expanded << {
          backtrace: exception.backtrace,
        }
      end
    end

    trace = Buildkite::TestCollector::CucumberPlugin::Trace.new(
      scenario,
      history:          tracer.history,
      failure_reason:   failure_reason,
      failure_expanded: failure_expanded,
      tags:             tags,
    )

    Buildkite::TestCollector.uploader.traces[scenario.location.to_s] = trace

    if Buildkite::TestCollector.session
      Buildkite::TestCollector.session.add_example_to_send_queue(scenario.location.to_s)
    end
  end
end

at_exit do
  if Buildkite::TestCollector.session
    Buildkite::TestCollector.session.send_remaining_data
    Buildkite::TestCollector.session.close
  end
end

# Initialise shared tracing & session behaviour once hooks file is loaded.
Buildkite::TestCollector.enable_tracing!
Buildkite::TestCollector.session = Buildkite::TestCollector::Session.new
