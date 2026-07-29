# frozen_string_literal: true

require "buildkite/test_collector/rspec_plugin/reporter"

RSpec.describe Buildkite::TestCollector::RSpecPlugin::Reporter do

  it "test reporter works with a passed RSpec example" do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :passed)
    trace = fake_trace(a_example)
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    reset_io(io)
  end

  it "test reporter works with a failed RSpec example" do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :failed)
    trace = fake_trace(a_example)
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    reset_io(io)
  end

  it "queues the execution and finishes the span when OpenTelemetry metadata fails" do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
    )
    reporter = Buildkite::TestCollector::RSpecPlugin::Reporter.new(StringIO.new)
    a_example = fake_example(status: :passed)
    trace = fake_trace(a_example)
    span = double("OpenTelemetry span")
    allow(span).to receive(:finish)
    allow(trace).to receive(:otel_span) { span }
    allow(trace).to receive(:otel_attributes).and_raise(ArgumentError, "invalid metadata")
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)

    expect { reporter.handle_example(notification) }.not_to raise_error
    expect(span).to have_received(:finish).once
    expect(Buildkite::TestCollector.session).to have_received(:add_example_to_send_queue).with(a_example.id)
  end
end
