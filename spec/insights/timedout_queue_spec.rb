# frozen_string_literal: true

require "rspec/buildkite/insights/timedout_queue"

RSpec.describe RSpec::Buildkite::Insights::TimedoutQueue do
  describe "#pop" do
    it "raises after over set timeout" do
      timedout_queue = RSpec::Buildkite::Insights::TimedoutQueue.new(0)

      expect do
        timedout_queue.pop
      end.to raise_error RSpec::Buildkite::Insights::TimeoutError
    end
  end
end
