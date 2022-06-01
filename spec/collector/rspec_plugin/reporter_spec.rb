# frozen_string_literal: true

require "buildkite/collector/rspec_plugin/reporter"
require "buildkite/collector/uploader"

RSpec.describe Buildkite::Collector::RSpecPlugin::Reporter do

  it "test reporter works with a passed RSpec example" do
    Buildkite::Collector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
    )
    io = StringIO.new
    reporter = Buildkite::Collector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :passed)
    trace = fake_trace(a_example)
    allow(Buildkite::Collector.uploader).to receive(:traces) { trace }
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    reset_io(io)
  end

  it "test reporter works with a failed RSpec example" do
    Buildkite::Collector.configure(
      hook: :rspec,
      token: "fake",
      url: "http://fake.buildkite.localhost/v1/uploads",
    )
    io = StringIO.new
    reporter = Buildkite::Collector::RSpecPlugin::Reporter.new(io)
    a_example = fake_example(status: :failed)
    trace = fake_trace(a_example)
    allow(Buildkite::Collector.uploader).to receive(:traces) { trace }
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)
    allow(notification).to receive(:colorized_message_lines) { [""] }

    # does this raise an error?
    reporter.handle_example(notification)

    reset_io(io)
  end
end
