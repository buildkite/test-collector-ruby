# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe RSpec::Buildkite::Insights::CI::Buildkite do
  describe ".key" do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    context "Buildkite" do
      let(:build_url) { "https://buildkite.com/buildkite/buildkite/builds/1234" }

      before do
        fake_env("BUILDKITE", "true")
        fake_env("BUILDKITE_BUILD_URL", build_url)
      end

      it "returns build url" do
        result = RSpec::Buildkite::Insights::CI.key

        expect(result).to eq build_url
      end
    end
  end
end
