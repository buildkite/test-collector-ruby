# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe "RSpec::Buildkite::Insights::CI" do
  describe ".key" do
    it "returns random uuid if we cant detect CI" do
      uuid = "a8959bf2-e0af-4829-a029-97999f1b09d6"
      allow(SecureRandom).to receive(:uuid) { uuid }

      result = RSpec::Buildkite::Insights::CI.key

      expect(result).to eq uuid
    end
  end
end
