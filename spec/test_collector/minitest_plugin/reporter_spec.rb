# frozen_string_literal: true

require "minitest"
require "buildkite/test_collector/minitest_plugin/reporter"

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

  it "test reporter doesn't send a passed minitest result if failures_only is true" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    http = double("http", post: response)
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new) { http }
    Buildkite::TestCollector.configure(
      hook: :minitest,
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads",
      failures_only: true,
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace", source_location: "test.rb:1")
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    result = double("Result", assertions: 1, passed?: true, skipped?: false, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    expect(Buildkite::TestCollector.session).not_to have_received(:add_example_to_send_queue)
    reset_io(io)
  end

  it "test reporter doesn't send a skipped minitest result if failures_only is true" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    http = double("http", post: response)
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new) { http }
    Buildkite::TestCollector.configure(
      hook: :minitest,
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads",
      failures_only: true,
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace", source_location: "test.rb:1")
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    result = double("Result", assertions: 1, passed?: false, skipped?: true, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    expect(Buildkite::TestCollector.session).not_to have_received(:add_example_to_send_queue)
    reset_io(io)
  end

  it "test reporter sends a failed minitest result if failures_only is true" do
    response = double("Fake Response", code: 200, body: {}, to_hash: {})
    http = double("http", post: response)
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new) { http }
    Buildkite::TestCollector.configure(
      hook: :minitest,
      token: "fake",
      url: "http://fake.buildkite.example/v1/uploads",
      failures_only: true,
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::MinitestPlugin::Reporter.new(io, {})
    trace = double("Trace", source_location: "test.rb:1")
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { { "test.rb:1" => trace } }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    result = double("Result", assertions: 1, passed?: false, skipped?: false, source_location: "test.rb:1")

    # does this raise an error?
    reporter.record(result)

    expect(Buildkite::TestCollector.session).to have_received(:add_example_to_send_queue)
    reset_io(io)
  end
end
