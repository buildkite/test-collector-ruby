# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector do
  # Perhaps there's a better way to make a stubbed ENV overlay that resets between tests.
  # We could probably use allow(ENV).to receive(...) although I find that more fragile.
  # Also, I hadn't seen spec/support/fake_env_helpers.rb when I wrote this :|
  ENV_REAL = ENV
  let(:env_overlay) { Hash.new { |_h, k| ENV_REAL[k] } }
  before { stub_const("ENV", env_overlay) }

  context "RSpec" do
    let(:hook) { :rspec }

    it "can configure api_token and url" do
      analytics = Buildkite::TestCollector
      env_overlay["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      analytics.configure(hook: hook)

      expect(analytics.api_token).to eq "MyToken"
      expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
    end

    it "can configure custom env" do
      analytics = Buildkite::TestCollector
      env = { test: "test value" }

      analytics.configure(hook: hook, env: env)

      expect(analytics.env).to match env
    end

    it "can configure (and unconfigure) trace_min_duration" do
      Buildkite::TestCollector.configure(hook: hook)
      expect(Buildkite::TestCollector.trace_min_duration).to eq(nil)

      env_overlay["BUILDKITE_ANALYTICS_TRACE_MIN_MS"] = "123"
      Buildkite::TestCollector.configure(hook: hook)
      expect(Buildkite::TestCollector.trace_min_duration).to eq(0.123)

      env_overlay.delete("BUILDKITE_ANALYTICS_TRACE_MIN_MS")
      Buildkite::TestCollector.configure(hook: hook)
      expect(Buildkite::TestCollector.trace_min_duration).to eq(nil)
    end

    it "enables OpenTelemetry independently of legacy detailed tracing" do
      run_env = { "key" => "run-key" }
      allow(Buildkite::TestCollector::CI).to receive(:env) { run_env }
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)

      Buildkite::TestCollector.configure(
        hook: hook,
        tracing_enabled: false,
        otlp_endpoint: "https://example.invalid/v1/traces",
      )

      expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
        endpoint: "https://example.invalid/v1/traces",
        run_env: run_env,
      )
    end

    it "uses the environment OpenTelemetry endpoint through the same path" do
      env_overlay["BUILDKITE_ANALYTICS_OTLP_ENDPOINT"] = "https://example.invalid/v1/traces"
      allow(Buildkite::TestCollector::CI).to receive(:env) { { "key" => "run-key" } }
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)

      Buildkite::TestCollector.configure(hook: hook)

      expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
        endpoint: "https://example.invalid/v1/traces",
        run_env: { "key" => "run-key" },
      )
    end
  end

  context "Minitest" do
    let(:hook) { :minitest }

    it "can configure api_token and url" do
      analytics = Buildkite::TestCollector
      env_overlay["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      analytics.configure(hook: hook)

      expect(analytics.api_token).to eq "MyToken"
      expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
    end

    it "can configure custom env" do
      analytics = Buildkite::TestCollector
      env = { test: "test value" }

      analytics.configure(hook: hook, env: env)

      expect(analytics.env).to match env
    end

    it "does not enable the RSpec-only OpenTelemetry integration" do
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)

      Buildkite::TestCollector.configure(
        hook: hook,
        otlp_endpoint: "https://example.invalid/v1/traces",
      )

      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)
    end
  end

  context "Cucumber" do
    let(:hook) { :cucumber }

    if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7')
      before do
        Cucumber::Runtime.new
      end

      it "can configure api_token and url" do
        analytics = Buildkite::TestCollector
        env_overlay["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

        analytics.configure(hook: hook)

        expect(analytics.api_token).to eq "MyToken"
        expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
      end

      it "can configure custom env" do
        analytics = Buildkite::TestCollector
        env = { test: "test value" }

        analytics.configure(hook: hook, env: env)

        expect(analytics.env).to match env
      end

      it "does not enable the RSpec-only OpenTelemetry integration" do
        allow(Buildkite::TestCollector::OTel).to receive(:configure!)

        Buildkite::TestCollector.configure(
          hook: hook,
          otlp_endpoint: "https://example.invalid/v1/traces",
        )

        expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)
      end
    else
      it "raises an UnsupportedFrameworkError" do
        analytics = Buildkite::TestCollector
        env_overlay["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

        expect {
          analytics.configure(hook: hook)
        }.to raise_error(Buildkite::TestCollector::UnsupportedFrameworkError, "Cucumber is only supported in versions of Ruby >= 2.7")
      end
    end
  end
end
