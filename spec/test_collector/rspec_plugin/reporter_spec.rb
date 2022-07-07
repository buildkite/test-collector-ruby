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
end
