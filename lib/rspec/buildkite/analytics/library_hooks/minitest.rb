require "minitest"

puts "loading minitest plugin" 

# require_relative '../reporter'
require_relative "../uploader"

RSpec::Buildkite::Analytics.uploader = RSpec::Buildkite::Analytics::Uploader

module BuildkiteMiniTestPlugin
  def before_setup
    super
    tracer = RSpec::Buildkite::Analytics::Tracer.new
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

      trace = RSpec::Buildkite::Analytics::Uploader::Trace.new(self, tracer.history)
      RSpec::Buildkite::Analytics.uploader.traces << trace
    end
  end
end

class MiniTest::Test
  include BuildkiteMiniTestPlugin
end


RSpec::Buildkite::Analytics::Network.configure
RSpec::Buildkite::Analytics::Object.configure

ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  RSpec::Buildkite::Analytics::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
end

RSpec::Buildkite::Analytics::Uploader.configure