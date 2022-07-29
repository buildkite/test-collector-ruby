# frozen_string_literal: true

require "minitest"

require_relative "../minitest_plugin"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

class Minitest::Test
  include Buildkite::TestCollector::MinitestPlugin
end

Buildkite::TestCollector.enable_tracing!

Buildkite::TestCollector.safe { Buildkite::TestCollector::Uploader.configure }
