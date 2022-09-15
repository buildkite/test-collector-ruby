# frozen_string_literal: true
require "timeout"

RSpec.describe Buildkite::TestCollector::CI do
  it "sleep without duration should not error" do
    Buildkite::TestCollector::Object.configure

    expect do
      ::Timeout.timeout(0.5) do
        sleep
      end
    end.to raise_error(Timeout::Error)
  end
end
