# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe RSpec::Buildkite::Insights::CI::GitHubActions do
  describe ".key" do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    context "GitHub Actions" do
      let(:build_url) { "https://github.com/buildkite/buildkite/actions/runs/1234" }

      before do
        fake_env("GITHUB_ACTIONS", "true")
        fake_env("GITHUB_REPOSITORY", "buildkite/buildkite")
        fake_env("GITHUB_RUN_ID", "1234")
      end

      it "returns build url" do
        result = RSpec::Buildkite::Insights::CI.key

        expect(result).to eq build_url
      end
    end
  end
end
