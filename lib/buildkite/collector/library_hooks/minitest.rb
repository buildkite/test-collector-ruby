# frozen_string_literal: true

require "minitest"

require_relative "../uploader"
require_relative "../minitest_plugin"

Buildkite::Collector.uploader = Buildkite::Collector::Uploader

class MiniTest::Test
  include Buildkite::Collector::MinitestPlugin
end

Buildkite::Collector::Network.configure
Buildkite::Collector::Object.configure

ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  Buildkite::Collector::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
end

Buildkite::Collector::Uploader.configure
