# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::CI do
  describe ".env" do
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
      fake_env("BUILDKITE_BUILD_ID", nil)
      fake_env("BUILDKITE_ANALYTICS_LOCATION_PREFIX", nil)

      Buildkite::TestCollector.configure(hook: :rspec, env: { "test" => test_value })
    end

    it "merges in the custom env" do
      result = Buildkite::TestCollector::CI.env

      expect(result["test"]).to eq test_value
    end

    it "omits location_prefix when it is not configured" do
      result = Buildkite::TestCollector::CI.env

      expect(result).not_to include("location_prefix")
    end

    it "includes the configured test_runner in run_env" do
      result = Buildkite::TestCollector::CI.env

      expect(result).to include("test_runner" => "rspec")
    end

    context "with configured location_prefix" do
      before do
        Buildkite::TestCollector.configure(
          hook: :rspec,
          env: { "test" => test_value },
          location_prefix: "some-sub-dir"
        )
      end

      it "includes location_prefix in run_env" do
        expect(Buildkite::TestCollector::CI.env).to include(
          "location_prefix" => "some-sub-dir",
        )
      end
    end

    context "with BUILDKITE_ANALYTICS_LOCATION_PREFIX" do
      before do
        fake_env("BUILDKITE_ANALYTICS_LOCATION_PREFIX", "some-sub-dir")
        Buildkite::TestCollector.configure(hook: :rspec, env: { "test" => test_value })
      end

      it "includes location_prefix in run_env" do
        expect(Buildkite::TestCollector::CI.env).to include(
          "location_prefix" => "some-sub-dir",
        )
      end
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
          "test_runner" => "rspec",
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
            "test_runner" => "rspec",
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
          "test_runner" => "rspec",
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
            "test_runner" => "rspec",
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
