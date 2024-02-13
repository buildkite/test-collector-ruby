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

  it "test reporter doesn't send a passed RSpec example if failures_only is true" do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
      failures_only: true,
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :passed)
    trace = fake_trace(a_example)
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    expect(Buildkite::TestCollector.session).not_to have_received(:add_example_to_send_queue)
    reset_io(io)
  end

  it "test reporter doesn't send a pending RSpec example if failures_only is true" do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
      failures_only: true,
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :pending)
    trace = fake_trace(a_example)
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    expect(Buildkite::TestCollector.session).not_to have_received(:add_example_to_send_queue)
    reset_io(io)
  end

  it "test reporter sends a failed RSpec example if failures_only is true" do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
      failures_only: true,
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :failed)
    trace = fake_trace(a_example)
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    allow(Buildkite::TestCollector.session).to receive(:add_example_to_send_queue)
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    expect(Buildkite::TestCollector.session).to have_received(:add_example_to_send_queue)
    reset_io(io)
  end
end
