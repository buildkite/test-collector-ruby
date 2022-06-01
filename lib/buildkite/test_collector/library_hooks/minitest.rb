# frozen_string_literal: true

require "minitest"

require_relative "../uploader"
require_relative "../minitest_plugin"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

class MiniTest::Test
  include Buildkite::TestCollector::MinitestPlugin
end

Buildkite::TestCollector::Network.configure
Buildkite::TestCollector::Object.configure

ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  Buildkite::TestCollector::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
end

Buildkite::TestCollector::Uploader.configure
