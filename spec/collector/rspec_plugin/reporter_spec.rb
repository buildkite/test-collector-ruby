# frozen_string_literal: true

require "buildkite/collector/rspec_plugin/reporter"
require "buildkite/collector/uploader"

RSpec.describe Buildkite::Collector::RSpecPlugin::Reporter do
  class FakeExecutionResult
    attr :started_at, :finished_at, :run_time, :status, :exception
    def initialize(status: :passed, skipped: false, pending_fixed: false, exception: nil)
      now = Time.now
      @started_at = now
      @finished_at = now + rand(5)
      @run_time = finished_at - started_at
      @status = status
      @skipped = skipped
      @pending_fixed = pending_fixed
      @exception = status == :failed ? StandardError.new("fake error") : nil
    end
    def example_skipped?
      @skipped
    end
    def pending_fixed?
      @pending_fixed
    end
  end

  def fake_example(status:)
    example = double("RSpec::Core::Example")
    allow(example).to receive(:execution_result) { FakeExecutionResult.new(status: :failed) }
    allow(example).to receive(:id) { "spec/fake/fake_spec[1:2:3]" }
    allow(example).to receive(:full_description) { "this is a fake error full description" }
    allow(example).to receive(:metadata) { Hash.new(shared_group_inclusion_backtrace: []) }
    example
  end

  def fake_trace(a_example)
    fake_trace = double("Buildkite::Collector::RSpecPlugin::Trace", example: a_example)
    allow(fake_trace).to receive(:[]) { fake_trace }
    allow(fake_trace).to receive(:example=)
    allow(fake_trace).to receive(:failure_reason=)
    allow(fake_trace).to receive(:failure_expanded=)
    fake_trace
  end

  it "test reporter works with a passed RSpec example" do
    Buildkite::Collector.configure(
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

    reporter.handle_example(notification)

    reset_io(io)
  end

  it "test reporter works with a failed RSpec example" do
    Buildkite::Collector.configure(
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

    reporter.handle_example(notification)

    reset_io(io)
  end
end
