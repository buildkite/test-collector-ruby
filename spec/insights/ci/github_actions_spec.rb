# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe RSpec::Buildkite::Insights::CI::GitHubActions do
  describe ".env" do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    context "GitHub Actions" do
      let(:action_id) { "161335" }
      let(:run_id) { "840583718" }
      let(:run_num) { "2" }
      let(:repository) { "buildkite/buildkite" }
      let(:branch) { "refs/heads/feature-branch-1" }
      let(:commit_sha) { "9683a9a92ec0f3055849cd5488e8e9347c6e2878" }

      before do
        fake_env("GITHUB_ACTIONS", "true")
        fake_env("GITHUB_ACTION", action_id)
        fake_env("GITHUB_RUN_ID", run_id)
        fake_env("GITHUB_RUN_NUMBER", run_num)
        fake_env("GITHUB_REPOSITORY", repository)
        fake_env("GITHUB_REF", branch)
        fake_env("GITHUB_SHA", commit_sha)
      end

      it "returns env" do
        result = RSpec::Buildkite::Insights::CI.env

        expect(result).to match({
          "CI" => "github_actions",
          "key" => "161335-840583718-2",
          "url" => "https://github.com/buildkite/buildkite/actions/runs/840583718",
          "branch" => branch,
          "commit_sha" => commit_sha,
        })
      end
    end
  end
end
