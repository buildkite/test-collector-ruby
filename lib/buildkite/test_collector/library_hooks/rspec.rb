# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require_relative "../rspec_plugin/reporter"
require_relative "../rspec_plugin/trace"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

RSpec.configure do |config|
  config.before(:suite) do
    config.add_formatter Buildkite::TestCollector::RSpecPlugin::Reporter

    Buildkite::TestCollector::Uploader.configure
  end

  config.around(:each) do |example|
    tracer = Buildkite::TestCollector::Tracer.new

    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
    example.run
    Thread.current[:_buildkite_tracer] = nil

    tracer.finalize

    trace = Buildkite::TestCollector::RSpecPlugin::Trace.new(example, history: tracer.history)
    Buildkite::TestCollector.uploader.traces[example.id] = trace
  end
end

Buildkite::TestCollector.enable_tracing!
