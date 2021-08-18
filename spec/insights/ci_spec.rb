# frozen_string_literal: true

require "rspec/buildkite/insights/ci"

RSpec.describe "RSpec::Buildkite::Insights::CI" do
  describe ".env" do
    let(:build_uuid) { "b8959ui2-l0dk-4829-i029-97999t1e09d6" }
    let(:build_url) { "https://buildkite.com/buildkite/buildkite/builds/1234" }
    let(:branch) { "main" }
    let(:commit_sha) { "3683a9a92ec0f3055849cd5488e8e9347c6e2878" }
    let(:number) { "4242" }

    before do
      allow(ENV).to receive(:[]).and_call_original
      fake_env("BUILDKITE", "true")
      fake_env("BUILDKITE_BUILD_ID", build_uuid)
      fake_env("BUILDKITE_BUILD_URL", build_url)
      fake_env("BUILDKITE_BRANCH", branch)
      fake_env("BUILDKITE_COMMIT", commit_sha)
      fake_env("BUILDKITE_BUILD_NUMBER", number)
    end

    it "returns env" do
      result = RSpec::Buildkite::Insights::CI.env

      expect(result).to match({
        "CI" => "buildkite",
        "key" => build_uuid,
        "url" => build_url,
        "branch" => branch,
        "commit_sha" => commit_sha,
        "number" => number,
      })
    end
  end
end
