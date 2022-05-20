require "rspec/core"
require "rspec/expectations"

require_relative "../uploader"
require_relative "../rspec_plugin/reporter"
require_relative "../rspec_plugin/trace"

Buildkite::Collector.uploader = Buildkite::Collector::Uploader

RSpec.configure do |config|
  config.before(:suite) do
    config.add_formatter Buildkite::Collector::RSpecPlugin::Reporter

    Buildkite::Collector::Uploader.configure
  end

  config.around(:each) do |example|
    tracer = Buildkite::Collector::Tracer.new

    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
    example.run
    Thread.current[:_buildkite_tracer] = nil

    tracer.finalize

    trace = Buildkite::Collector::RSpecPlugin::Trace.new(example, history: tracer.history)
    Buildkite::Collector.uploader.traces[example.id] = trace
  end
end

Buildkite::Collector::Network.configure
Buildkite::Collector::Object.configure

ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  Buildkite::Collector::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
end
