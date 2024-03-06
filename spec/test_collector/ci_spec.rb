# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::CI do
  describe ".env" do
    let(:ci) { "true" }
    let(:key) { Buildkite::TestCollector::UUID.call }
    let(:url) { "http://example.com" }
    let(:branch) { "not-main" }
    let(:sha) { "a2c5ef54" }
    let(:number) { "424242" }
    let(:job_id) { "242424" }
    let(:message) { "bananas are tasty" }
    let(:version) { Buildkite::TestCollector::VERSION }
    let(:language_version) { RUBY_VERSION }
    let(:name) { "ruby-#{Buildkite::TestCollector::NAME}" }
    let(:test_value) { "test_value" }

    before do
      allow(ENV).to receive(:[]).and_call_original

      # these have to be reset or these tests will fail on these platforms
      fake_env("CI", nil)
      fake_env("BUILDKITE_BUILD_ID", nil)
      fake_env("GITHUB_RUN_NUMBER", nil)
      fake_env("CIRCLE_BUILD_NUM", nil)

      Buildkite::TestCollector.configure(hook: :rspec, env: { "test" => test_value })
    end

    it "merges in the custom env" do
      result = Buildkite::TestCollector::CI.env

      expect(result["test"]).to eq test_value
    end

    context "when running on Buildkite" do
      let(:bk_build_uuid) { "b8959ui2-l0dk-4829-i029-97999t1e09d6" }
      let(:bk_build_url) { "https://buildkite.com/buildkite/buildkite/builds/1234" }
      let(:bk_branch) { "main" }
      let(:bk_sha) { "3683a9a92ec0f3055849cd5488e8e9347c6e2878" }
      let(:bk_number) { "4242" }
      let(:bk_job_id) { "j3459ui2-l0dk-4829-i029-97999t1e09d6" }
      let(:bk_message) { "Merge pull request #1 from buildkite/branch\n commit title" }

      before do
        fake_env("CI", ci)
        fake_env("BUILDKITE_BUILD_ID", bk_build_uuid)
        fake_env("BUILDKITE_BUILD_URL", bk_build_url)
        fake_env("BUILDKITE_BRANCH", bk_branch)
        fake_env("BUILDKITE_COMMIT", bk_sha)
        fake_env("BUILDKITE_BUILD_NUMBER", bk_number)
        fake_env("BUILDKITE_JOB_ID", bk_job_id)
        fake_env("BUILDKITE_MESSAGE", bk_message)
      end

      it "returns all env" do
        result = Buildkite::TestCollector::CI.env

        expect(result).to match({
          "CI" => "buildkite",
          "key" => bk_build_uuid,
          "url" => bk_build_url,
          "branch" => bk_branch,
          "commit_sha" => bk_sha,
          "number" => bk_number,
          "job_id" => bk_job_id,
          "message" => bk_message,
          "language_version" => language_version,
          "version" => version,
          "collector" => name,
          "test" => test_value,
        })
      end

      context "when setting the analytics env" do
        before do
          fake_env("BUILDKITE_ANALYTICS_KEY", key)
          fake_env("BUILDKITE_ANALYTICS_URL", url)
          fake_env("BUILDKITE_ANALYTICS_BRANCH", branch)
          fake_env("BUILDKITE_ANALYTICS_SHA", sha)
          fake_env("BUILDKITE_ANALYTICS_NUMBER", number)
          fake_env("BUILDKITE_ANALYTICS_JOB_ID", job_id)
          fake_env("BUILDKITE_ANALYTICS_MESSAGE", message)
          fake_env("BUILDKITE_ANALYTICS_EXECUTION_NAME_PREFIX", "execution_name_prefix")
          fake_env("BUILDKITE_ANALYTICS_EXECUTION_NAME_SUFFIX", "execution_name_suffix")
        end

        it "returns the analytics env" do
          result = Buildkite::TestCollector::CI.env

          expect(result).to match({
            "CI" => "buildkite",
            "key" => key,
            "url" => url,
            "branch" => branch,
            "commit_sha" => sha,
            "number" => number,
            "job_id" => job_id,
            "message" => message,
            "execution_name_prefix" => "execution_name_prefix",
            "execution_name_suffix" => "execution_name_suffix",
            "language_version" => language_version,
            "version" => version,
            "collector" => name,
            "test" => test_value,
          })
        end
      end
    end

    context "when running on GitHub Actions" do
      let(:gha_run_number) { "4242" }
      let(:gha_action) { "some_action" }
      let(:gha_run_attempt) { "1" }
      let(:gha_run_id) { "2424" }
      let(:gha_repository) { "rofl/lol" }
      let(:gha_ref) { "main" }
      let(:gha_sha) { "3683a9a92ec0f3055849cd5488e8e9347c6e2878" }

      before do
        fake_env("CI", ci)
        fake_env("GITHUB_RUN_NUMBER", gha_run_number)
        fake_env("GITHUB_ACTION", gha_action)
        fake_env("GITHUB_RUN_ATTEMPT", gha_run_attempt)
        fake_env("GITHUB_RUN_ID", gha_run_id)
        fake_env("GITHUB_REPOSITORY", gha_repository)
        fake_env("GITHUB_REF_NAME", gha_ref)
        fake_env("GITHUB_SHA", gha_sha)
      end

      it "returns all env" do
        result = Buildkite::TestCollector::CI.env

        expect(result).to match({
          "CI" => "github_actions",
          "key" => "some_action-4242-1",
          "url" => "https://github.com/rofl/lol/actions/runs/2424",
          "branch" => gha_ref,
          "commit_sha" => gha_sha,
          "number" => gha_run_number,
          "language_version" => language_version,
          "version" => version,
          "collector" => name,
          "test" => test_value,
        })
      end

      context "when setting the analytics env" do
        before do
          fake_env("BUILDKITE_ANALYTICS_KEY", key)
          fake_env("BUILDKITE_ANALYTICS_URL", url)
          fake_env("BUILDKITE_ANALYTICS_BRANCH", branch)
          fake_env("BUILDKITE_ANALYTICS_SHA", sha)
          fake_env("BUILDKITE_ANALYTICS_NUMBER", number)
          fake_env("BUILDKITE_ANALYTICS_JOB_ID", job_id)
          fake_env("BUILDKITE_ANALYTICS_MESSAGE", message)
        end

        it "returns the analytics env" do
          result = Buildkite::TestCollector::CI.env

          expect(result).to match({
            "CI" => "github_actions",
            "key" => key,
            "url" => url,
            "branch" => branch,
            "commit_sha" => sha,
            "number" => number,
            "job_id" => job_id,
            "message" => message,
            "language_version" => language_version,
            "version" => version,
            "collector" => name,
            "test" => test_value,
          })
        end
      end
    end

    context "when running on CircleCI" do
      let(:c_workflow_id) { "4242" }
      let(:c_number) { "2424" }
      let(:c_url) { "http://example.com/circle" }
      let(:c_branch) { "main" }
      let(:c_sha) { "3683a9a92ec0f3055849cd5488e8e9347c6e2878" }

      before do
        fake_env("CI", ci)
        fake_env("CIRCLE_WORKFLOW_ID", c_workflow_id)
        fake_env("CIRCLE_BUILD_NUM", c_number)
        fake_env("CIRCLE_BUILD_URL", c_url)
        fake_env("CIRCLE_BRANCH", c_branch)
        fake_env("CIRCLE_SHA1", c_sha)
      end

      it "returns all env" do
        result = Buildkite::TestCollector::CI.env

        expect(result).to match({
          "CI" => "circleci",
          "key" => "4242-2424",
          "url" => c_url,
          "branch" => c_branch,
          "commit_sha" => c_sha,
          "number" => c_number,
          "language_version" => language_version,
          "version" => version,
          "collector" => name,
          "test" => test_value,
        })
      end

      context "when setting the analytics env" do
        before do
          fake_env("BUILDKITE_ANALYTICS_KEY", key)
          fake_env("BUILDKITE_ANALYTICS_URL", url)
          fake_env("BUILDKITE_ANALYTICS_BRANCH", branch)
          fake_env("BUILDKITE_ANALYTICS_SHA", sha)
          fake_env("BUILDKITE_ANALYTICS_NUMBER", number)
          fake_env("BUILDKITE_ANALYTICS_JOB_ID", job_id)
          fake_env("BUILDKITE_ANALYTICS_MESSAGE", message)
        end

        it "returns the analytics env" do
          result = Buildkite::TestCollector::CI.env

          expect(result).to match({
            "CI" => "circleci",
            "key" => key,
            "url" => url,
            "branch" => branch,
            "commit_sha" => sha,
            "number" => number,
            "job_id" => job_id,
            "message" => message,
            "language_version" => language_version,
            "version" => version,
            "collector" => name,
            "test" => test_value,
          })
        end
      end
    end

    context "when running on Codeship" do
      let(:c_branch) { "main" }
      let(:c_build_id) { "build_id" }
      let(:c_pull_url) { "http://github.com/codeship" }
      let(:c_sha) { "3683a9a92ec0f3055849cd5488e8e9347c6e2878" }
      let(:c_message) { "merge something into main" }

      before do
        fake_env("CI_NAME", "codeship")
        fake_env("CI_BUILD_ID", c_build_id)
        fake_env("CI_PULL_REQUEST", c_pull_url)
        fake_env("CI_BRANCH", c_branch)
        fake_env("CI_COMMIT_ID", c_sha)
        fake_env("CI_COMMIT_MESSAGE", c_message)
      end

      it "returns all env" do
        result = Buildkite::TestCollector::CI.env

        expect(result).to match({
          "CI" => "codeship",
          "key" => c_build_id,
          "url" => c_pull_url,
          "branch" => c_branch,
          "commit_sha" => c_sha,
          "number" => nil,
          "message" => c_message,
          "language_version" => language_version,
          "version" => version,
          "collector" => name,
          "test" => test_value,
        })
      end

      context "when setting the analytics env" do
        before do
          fake_env("CI_NAME", "codeship")
          fake_env("BUILDKITE_ANALYTICS_KEY", key)
          fake_env("BUILDKITE_ANALYTICS_URL", url)
          fake_env("BUILDKITE_ANALYTICS_BRANCH", branch)
          fake_env("BUILDKITE_ANALYTICS_SHA", sha)
          fake_env("BUILDKITE_ANALYTICS_NUMBER", number)
          fake_env("BUILDKITE_ANALYTICS_JOB_ID", job_id)
          fake_env("BUILDKITE_ANALYTICS_MESSAGE", message)
        end

        it "returns the analytics env" do
          result = Buildkite::TestCollector::CI.env

          expect(result).to match({
            "CI" => "codeship",
            "key" => key,
            "url" => url,
            "branch" => branch,
            "commit_sha" => sha,
            "number" => number,
            "job_id" => job_id,
            "message" => message,
            "language_version" => language_version,
            "version" => version,
            "collector" => name,
            "test" => test_value,
          })
        end
      end
    end

    context "when running on a generic CI platform" do
      before do
        fake_env("CI", ci)

        allow(Buildkite::TestCollector::UUID).to receive(:call) { "845ac829-2ab3-4bbb-9e24-3529755a6d37" }
      end

      it "returns all env" do
        result = Buildkite::TestCollector::CI.env

        expect(result).to match({
          "CI" => "generic",
          "key" => key,
          "language_version" => language_version,
          "version" => version,
          "collector" => name,
          "test" => test_value,
        })
      end

      context "when setting the analytics env" do
        before do
          fake_env("BUILDKITE_ANALYTICS_KEY", key)
          fake_env("BUILDKITE_ANALYTICS_URL", url)
          fake_env("BUILDKITE_ANALYTICS_BRANCH", branch)
          fake_env("BUILDKITE_ANALYTICS_SHA", sha)
          fake_env("BUILDKITE_ANALYTICS_NUMBER", number)
          fake_env("BUILDKITE_ANALYTICS_JOB_ID", job_id)
          fake_env("BUILDKITE_ANALYTICS_MESSAGE", message)
        end

        it "returns the analytics env" do
          result = Buildkite::TestCollector::CI.env

          expect(result).to match({
            "CI" => "generic",
            "key" => key,
            "url" => url,
            "branch" => branch,
            "commit_sha" => sha,
            "number" => number,
            "job_id" => job_id,
            "message" => message,
            "language_version" => language_version,
            "version" => version,
            "collector" => name,
            "test" => test_value,
          })
        end
      end
    end

    context "when not running on a CI platform" do
      before do
        allow(Buildkite::TestCollector::UUID).to receive(:call) { "845ac829-2ab3-4bbb-9e24-3529755a6d37" }
      end

      it "returns all env" do
        result = Buildkite::TestCollector::CI.env

        expect(result).to match({
          "CI" => nil,
          "key" => "845ac829-2ab3-4bbb-9e24-3529755a6d37",
          "language_version" => language_version,
          "version" => version,
          "collector" => name,
          "test" => test_value,
        })
      end

      context "when setting the analytics env" do
        before do
          fake_env("BUILDKITE_ANALYTICS_KEY", key)
          fake_env("BUILDKITE_ANALYTICS_URL", url)
          fake_env("BUILDKITE_ANALYTICS_BRANCH", branch)
          fake_env("BUILDKITE_ANALYTICS_SHA", sha)
          fake_env("BUILDKITE_ANALYTICS_NUMBER", number)
          fake_env("BUILDKITE_ANALYTICS_JOB_ID", job_id)
          fake_env("BUILDKITE_ANALYTICS_MESSAGE", message)
        end

        it "returns the analytics env" do
          result = Buildkite::TestCollector::CI.env

          expect(result).to match({
            "CI" => nil,
            "key" => key,
            "url" => url,
            "branch" => branch,
            "commit_sha" => sha,
            "number" => number,
            "job_id" => job_id,
            "message" => message,
            "language_version" => language_version,
            "version" => version,
            "collector" => name,
            "test" => test_value,
          })
        end
      end
    end

    context "with trace_min_duration" do
      before do
        fake_env("BUILDKITE_ANALYTICS_TRACE_MIN_MS", "123")
        Buildkite::TestCollector.configure(hook: :rspec)
      end

      it "includes trace_min_duration in run_env" do
        expect(Buildkite::TestCollector::CI.env).to include(
          "trace_min_duration" => "0.123",
        )
      end
    end
  end
end
