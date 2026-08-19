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
        otel_instrumentations: [],
      )

      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)

      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
        endpoint: "https://tests-otlp.buildkite.com/v1/traces",
        api_token: "MyToken",
        run_env: run_env,
        instrumentations: [],
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

    it "submits results only via OTLP when otel_only is set, with tags as resource attributes" do
      run_env = { "key" => "run-key" }
      allow(Buildkite::TestCollector::CI).to receive(:env) { run_env }
      allow(Buildkite::TestCollector::OTel).to receive(:configure!)
      env_overlay["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      Buildkite::TestCollector.configure(
        hook: hook,
        otel_only: true,
        tags: { "team" => "platform" },
      )

      expect(Buildkite::TestCollector.otel_only?).to eq true
      expect(Buildkite::TestCollector::OTel).not_to have_received(:configure!)

      Buildkite::TestCollector.start_otel

      expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
        endpoint: "https://tests-otlp.buildkite.com/v1/traces",
        api_token: "MyToken",
        run_env: run_env,
        otel_only: true,
        instrumentations: nil,
        resource_attributes: { "team" => "platform" },
      )
    ensure
      Buildkite::TestCollector.otel_only = false
    end

    it "routes annotations to OpenTelemetry in OTLP-only mode" do
      allow(Buildkite::TestCollector::OTel).to receive(:annotate)
      Buildkite::TestCollector.otel_only = true

      Buildkite::TestCollector.annotate("a thing happened")

      expect(Buildkite::TestCollector::OTel).to have_received(:annotate).with("a thing happened")
    ensure
      Buildkite::TestCollector.otel_only = false
    end
  end

  context "worker ID tag" do
    let(:hook) { :rspec }

    it "tags executions with ci.worker.id from BUILDKITE_AGENT_ID" do
      env_overlay["BUILDKITE_AGENT_ID"] = "agent-123"

      Buildkite::TestCollector.configure(hook: hook)

      expect(Buildkite::TestCollector.tags).to eq("ci.worker.id" => "agent-123")
    end

    it "omits the tag when BUILDKITE_AGENT_ID is unset" do
      env_overlay.delete("BUILDKITE_AGENT_ID")

      Buildkite::TestCollector.configure(hook: hook)

      expect(Buildkite::TestCollector.tags).to eq({})
    end

    it "omits the tag when BUILDKITE_AGENT_ID is empty" do
      env_overlay["BUILDKITE_AGENT_ID"] = ""

      Buildkite::TestCollector.configure(hook: hook)

      expect(Buildkite::TestCollector.tags).to eq({})
    end

    it "omits the tag when BUILDKITE_AGENT_ID is whitespace-only" do
      env_overlay["BUILDKITE_AGENT_ID"] = "   "

      Buildkite::TestCollector.configure(hook: hook)

      expect(Buildkite::TestCollector.tags).to eq({})
    end

    it "lets an explicit caller-supplied tag override the automatic one" do
      env_overlay["BUILDKITE_AGENT_ID"] = "agent-123"

      Buildkite::TestCollector.configure(hook: hook, tags: { "ci.worker.id" => "custom" })

      expect(Buildkite::TestCollector.tags).to eq("ci.worker.id" => "custom")
    end

    it "preserves other caller-supplied tags alongside the automatic one" do
      env_overlay["BUILDKITE_AGENT_ID"] = "agent-123"

      Buildkite::TestCollector.configure(hook: hook, tags: { "team" => "test-engine" })

      expect(Buildkite::TestCollector.tags).to eq(
        "ci.worker.id" => "agent-123",
        "team" => "test-engine",
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

    it "rejects otel_only rather than silently uploading nothing" do
      expect {
        Buildkite::TestCollector.configure(hook: hook, otel_only: true)
      }.to raise_error(ArgumentError, /otel_only is currently only supported with the rspec hook/)
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
