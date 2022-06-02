# frozen_string_literal: true

require "minitest"

require_relative "../uploader"
require_relative "../minitest_plugin"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

class MiniTest::Test
  include Buildkite::TestCollector::MinitestPlugin
end

Buildkite::TestCollector.enable_tracing!

Buildkite::TestCollector::Uploader.configure
