require "rspec/core"
require "rspec/expectations"

require_relative "../uploader"
require_relative "../reporter"

RSpec::Buildkite::Analytics.uploader = RSpec::Buildkite::Analytics::Uploader

RSpec::Core::Formatters.register(RSpec::Buildkite::Analytics::Reporter, :example_passed, :example_failed, :example_pending, :dump_summary)

RSpec.configure do |config|
  config.before(:suite) do
    config.add_formatter RSpec::Buildkite::Analytics::Reporter

    RSpec::Buildkite::Analytics::Uploader.configure
  end

  config.around(:each) do |example|
    tracer = RSpec::Buildkite::Analytics::Tracer.new

    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
    example.run
    Thread.current[:_buildkite_tracer] = nil

    tracer.finalize

    trace = RSpec::Buildkite::Analytics::Uploader::Trace.new(example, tracer.history)
    RSpec::Buildkite::Analytics.uploader.traces[example.id] = trace
  end
end

RSpec::Buildkite::Analytics::Network.configure
RSpec::Buildkite::Analytics::Object.configure

ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  RSpec::Buildkite::Analytics::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
end
