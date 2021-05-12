# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe RSpec::Buildkite::Insights::CI::CircleCI do
  describe ".key" do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    context "CircleCI" do
      let(:build_url) { "https://circleci.com/gh/circleci/frontend/1234" }

      before do
        fake_env("CIRCLECI", "true")
        fake_env("CIRCLE_BUILD_URL", build_url)
      end

      it "returns build url" do
        result = RSpec::Buildkite::Insights::CI.key

        expect(result).to eq build_url
      end
    end
  end
end
