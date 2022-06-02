# frozen_string_literal: true

require "minitest"
require "buildkite/test_collector/minitest_plugin/reporter"
require "buildkite/test_collector/uploader"

RSpec.describe Buildkite::TestCollector::MinitestPlugin::Reporter do
  it "test reporter works with a passed minitest result" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    http = double("http", post: response)
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new) { http }
    Buildkite::TestCollector.configure(
      hook: :minitest,
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads"
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace", source_location: "test.rb:1")
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    result = double("Result", assertions: 1, passed?: true, skipped?: false, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    reset_io(io)
  end

  it "test reporter works with a failed minitest result" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    http = double("http", post: response)
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new) { http }
    Buildkite::TestCollector.configure(
      hook: :minitest,
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads"
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace")
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    result = double("Result", assertions: 1, passed?: false, skipped?: false, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    reset_io(io)
  end
end
