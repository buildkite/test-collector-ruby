# frozen_string_literal: true

require "ostruct"

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

module RSpecExampleTraceHelpers
  def fake_example(opts = {})
    status = opts.delete(:status) || :failed
    execution_result = opts.delete(:execution_result) || FakeExecutionResult.new(status: status)
    file_path = opts.delete(:file_path) || "./spec/fake/fake_spec.rb"
    location = opts.delete(:location) || "#{file_path}:42"
    id = opts.delete(:id) || "#{file_path}[1:2:3]"
    full_description = opts.delete(:full_description) || "this is a fake example full description"
    description = opts.delete(:description) || "fake example name"
    metadata = opts.delete(:metadata) || { shared_group_inclusion_backtrace: [] }
    example_group = opts.delete(:example_group) || OpenStruct.new(metadata: { full_description: full_description })

    if opts.length > 0
      raise ArgumentError, "fake_example: unknown option(s) #{opts.keys.to_s}"
    end

    instance_double(
      RSpec::Core::Example,
      execution_result: execution_result,
      file_path: file_path,
      location: location,
      id: id,
      full_description: full_description,
      description: description,
      metadata: metadata,
      example_group: example_group
    )
  end

  def fake_trace(a_example)
    fake_trace = double("Buildkite::TestCollector::RSpecPlugin::Trace")
    allow(fake_trace).to receive(:[]) { fake_trace }
    allow(fake_trace).to receive(:result=)
    allow(fake_trace).to receive(:failure_reason=)
    allow(fake_trace).to receive(:failure_expanded=)
    fake_trace
  end
end

RSpec.configure do |config|
  config.include RSpecExampleTraceHelpers
end
