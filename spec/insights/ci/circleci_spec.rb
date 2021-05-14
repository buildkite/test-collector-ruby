# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe RSpec::Buildkite::Insights::CI::CircleCI do
  describe ".env" do
    before do
      allow(ENV).to receive(:[]).and_call_original
    end

    context "Circle CI" do
      let(:workflow_id) { "66a7325d-f222-41d5-a257-cc83bc8e6843" }
      let(:build_num) { "12345" }
      let(:build_url) { "https://circleci.com/gh/circleci/frontend/1234" }
      let(:branch) { "main" }
      let(:commit_sha) { "9883a9a92ec0f3055849cd5488e8e9347c6e2878" }

      before do

        fake_env("CIRCLECI", "true")
        fake_env("CIRCLE_WORKFLOW_ID", workflow_id)
        fake_env("CIRCLE_BUILD_NUM", build_num)
        fake_env("CIRCLE_BUILD_URL", build_url)
        fake_env("CIRCLE_BRANCH", branch)
        fake_env("CIRCLE_SHA1", commit_sha)
      end

      it "returns env" do
        result = RSpec::Buildkite::Insights::CI.env

        expect(result).to match({
          "CI" => "circleci",
          "key" => "66a7325d-f222-41d5-a257-cc83bc8e6843-12345",
          "url" => build_url,
          "branch" => branch,
          "commit_sha" => commit_sha,
        })
      end
    end
  end
end
