# frozen_string_literal: true

require "minitest"
require "buildkite/collector/minitest_plugin/reporter"
require "buildkite/collector/uploader"

RSpec.describe Buildkite::Collector::MinitestPlugin::Reporter do
  it "test reporter works with a passed minitest result" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    allow(Buildkite::Collector::HTTPClient).to receive(:post) { response }
    Buildkite::Collector.configure(
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads",
      hook: :minitest
    )
    io = StringIO.new
    reporter = Buildkite::Collector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace", source_location: "test.rb:1")
    allow(Buildkite::Collector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    result = double("Result", assertions: 1, passed?: true, skipped?: false, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    reset_io(io)
  end

  it "test reporter works with a failed minitest result" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    allow(Buildkite::Collector::HTTPClient).to receive(:post) { response }
    Buildkite::Collector.configure(
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads",
      hook: :minitest
    )
    io = StringIO.new
    reporter = Buildkite::Collector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace")
    allow(Buildkite::Collector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    result = double("Result", assertions: 1, passed?: false, skipped?: false, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    reset_io(io)
  end
end
