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

    it "leaves OpenTelemetry off unless it is opted into" do
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)

      Buildkite::TestCollector.configure(hook: hook)
      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)
    end

    it "stores OpenTelemetry options without setting it up during configuration" do
      run_env = { "key" => "run-key" }
      allow(Buildkite::TestCollector::CI).to receive(:env) { run_env }
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)
      env_overlay["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      Buildkite::TestCollector.configure(
        hook: hook,
        tracing_enabled: false,
        otel_enabled: true,
        otel_instrumentations: [:defaults, "OpenTelemetry::Instrumentation::Redis"],
      )

      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)

      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
        endpoint: "https://tests-otlp.buildkite.com/v1/traces",
        api_token: "MyToken",
        run_env: run_env,
        instrumentations: [:defaults, "OpenTelemetry::Instrumentation::Redis"],
      )
    end

    it "can override the endpoint for local development" do
      env_overlay["BUILDKITE_ANALYTICS_OTLP_ENDPOINT"] = "http://tests-otlp.buildkite.localhost/v1/traces"
      allow(Buildkite::TestCollector::CI).to receive(:env) { { "key" => "run-key" } }
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)

      Buildkite::TestCollector.configure(hook: hook, otel_enabled: true)
      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
        hash_including(
          endpoint: "http://tests-otlp.buildkite.localhost/v1/traces",
        ),
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
        otel_enabled: true,
      )
      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)
    end
  end

  context "Cucumber" do
    let(:hook) { :cucumber }

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
        otel_enabled: true,
      )
      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)
    end
  end
end
