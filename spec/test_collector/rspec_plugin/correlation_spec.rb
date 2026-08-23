# frozen_string_literal: true

require "opentelemetry/sdk"
require "rspec/core/sandbox"

RSpec.describe "RSpec execution and OpenTelemetry correlation" do
  # Runs one example through the collector's real around hook and the
  # span-finishing reporter. Sandboxed, so registering that hook doesn't
  # disturb the suite running this test. The hook file registers its
  # formatters from before(:suite), which group.run does not fire, so the
  # span-finishing one is added directly here (the JSON-uploading Reporter
  # stays out: it is not under test and would open an upload session).
  def run_sandboxed_example(metadata = {}, &block)
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"
      config.add_formatter Buildkite::TestCollector::RSpecPlugin::OTelReporter

      group = RSpec.describe("Correlated group") do
        it("passes", metadata, &(block || proc { nil }))
      end
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
  end

  it "sets up OpenTelemetry after application libraries have loaded" do
    run_env = { "key" => "run-key" }
    library_loaded_when_configured = nil
    allow(Buildkite::TestCollector::CI).to receive(:env) { run_env }
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("BUILDKITE_ANALYTICS_TOKEN").and_return(nil)
    allow(ENV).to receive(:[]).with("BUILDKITE_ANALYTICS_OTLP_ENDPOINT").and_return(nil)
    allow(Buildkite::TestCollector::OTel).to receive(:configure!) do
      library_loaded_when_configured = defined?(LateLoadedApplicationLibrary)
    end
    Buildkite::TestCollector.configure(hook: :rspec, otel_enabled: true)

    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"

      stub_const("LateLoadedApplicationLibrary", Module.new)
      group = RSpec.describe("Late-loaded application") { it("passes") { nil } }
      config.with_suite_hooks { group.run(RSpec.configuration.reporter) }
    end

    expect(Buildkite::TestCollector::OTel).to have_received(:configure!).with(
      endpoint: "https://tests-otlp.buildkite.com/v1/traces",
      api_token: nil,
      run_env: run_env,
      instrumentations: nil,
    )
    expect(library_loaded_when_configured).to eq("constant")
  end

  it "starts setup after the application configures its provider" do
    default_provider = OpenTelemetry::Internal::ProxyTracerProvider.new
    suite_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    active_provider = default_provider
    provider_when_configured = nil
    allow(OpenTelemetry).to receive(:tracer_provider) { active_provider }
    allow(Buildkite::TestCollector::OTel).to receive(:configure!) do
      provider_when_configured = OpenTelemetry.tracer_provider
    end
    Buildkite::TestCollector.configure(hook: :rspec, otel_enabled: true)

    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"

      active_provider = suite_provider
      group = RSpec.describe("Application-owned OpenTelemetry") { it("passes") { nil } }
      config.with_suite_hooks { group.run(RSpec.configuration.reporter) }
    end

    expect(provider_when_configured).to equal(suite_provider)
  ensure
    suite_provider&.shutdown
  end

  it "describes the execution on its span, and puts the span's trace ID on the upload" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, provider.tracer("correlation-test")
    )

    example = run_sandboxed_example
    provider.force_flush

    trace = Buildkite::TestCollector.uploader.traces.fetch(example.id)
    span = exporter.finished_spans.find { |finished| finished.name == "test.execution" }

    expect(span).not_to be_nil
    expect(trace.as_hash[:trace_id]).to eq(span.trace_id.unpack1("H*"))
    expect(span.attributes).to include(
      "test.case.name" => "Correlated group passes",
      "test.suite.name" => "Correlated group",
      "test.case.result.status" => "pass",
      "buildkite.test.execution.external_id" => trace.as_hash.fetch(:external_id),
    )
    expect(span.attributes.fetch("code.file.path")).to end_with("correlation_spec.rb")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)

    # The execution reports exactly what the span timed, not a second
    # measurement, and the history still describes itself.
    history = trace.as_hash[:history]
    expect(history[:duration])
      .to eq((span.end_timestamp - span.start_timestamp) / 1_000_000_000.0)
    # Within a nanosecond: start_at is seconds since boot, so adding a
    # sub-millisecond duration to it rounds.
    expect(history[:end_at] - history[:start_at])
      .to be_within(0.000000001).of(history[:duration])
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
    provider&.shutdown
  end

  it "marks a failed execution's span as an error" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, provider.tracer("correlation-test")
    )

    example = run_sandboxed_example { raise "nope" }
    provider.force_flush

    span = exporter.finished_spans.find { |finished| finished.name == "test.execution" }
    expect(span.attributes.fetch("test.case.result.status")).to eq("fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
    provider&.shutdown
  end

  it "reports a pending execution as skipped" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, provider.tracer("correlation-test")
    )

    example = run_sandboxed_example(pending: "not done yet") { raise "not done yet" }
    provider.force_flush

    span = exporter.finished_spans.find { |finished| finished.name == "test.execution" }
    expect(example.execution_result.status).to eq(:pending)
    expect(span.attributes.fetch("test.case.result.status")).to eq("skipped")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
    provider&.shutdown
  end

  it "classifies a failure raised by an outer around hook after the example ran" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, provider.tracer("correlation-test")
    )

    example = RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new

      # Registered before the collector's hook, so it wraps it: the
      # collector's hook has fully unwound (span handed off, still open)
      # before this raises. The span is only classified at reporter time,
      # once RSpec has recorded the failure.
      config.around(:each) do |inner|
        inner.run
        raise "outer boom"
      end

      load "buildkite/test_collector/library_hooks/rspec.rb"
      config.add_formatter Buildkite::TestCollector::RSpecPlugin::OTelReporter

      group = RSpec.describe("Correlated group") { it("passes") { nil } }
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
    provider.force_flush

    span = exporter.finished_spans.find { |finished| finished.name == "test.execution" }
    expect(example.execution_result.status).to eq(:failed)
    expect(span.attributes.fetch("test.case.result.status")).to eq("fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
    provider&.shutdown
  end

  it "classifies a pending example that unexpectedly passes as failed" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, provider.tracer("correlation-test")
    )

    example = run_sandboxed_example(pending: "not fixed yet")
    provider.force_flush

    span = exporter.finished_spans.find { |finished| finished.name == "test.execution" }
    expect(example.execution_result.status).to eq(:failed)
    expect(span.attributes.fetch("test.case.result.status")).to eq("fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
    provider&.shutdown
  end

  it "finishes spans through the reporter that before(:suite) registers" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, provider.tracer("correlation-test")
    )
    Buildkite::TestCollector.instance_variable_set(:@otel_options, nil)
    # before(:suite) also registers the JSON-uploading Reporter, whose
    # send queue needs a batch size; configure normally supplies it.
    Buildkite::TestCollector.batch_size ||= Buildkite::TestCollector::DEFAULT_UPLOAD_BATCH_SIZE

    example = RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"

      group = RSpec.describe("Correlated group") { it("passes") { nil } }
      config.with_suite_hooks { group.run(RSpec.configuration.reporter) }
      group.examples.first
    end
    provider.force_flush

    span = exporter.finished_spans.find { |finished| finished.name == "test.execution" }
    expect(span).not_to be_nil
    expect(span.attributes.fetch("test.case.result.status")).to eq("pass")
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
    provider&.shutdown
  end

  it "times the execution itself when OpenTelemetry is off" do
    expect(Buildkite::TestCollector::OTel).not_to be_enabled

    example = run_sandboxed_example

    trace = Buildkite::TestCollector.uploader.traces.fetch(example.id)
    history = trace.as_hash[:history]
    # Within a nanosecond: start_at is seconds since boot, so adding a
    # sub-millisecond duration to it rounds.
    expect(history[:end_at] - history[:start_at])
      .to be_within(0.000000001).of(history[:duration])
  ensure
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
  end

  it "sends no trace ID when OpenTelemetry is off" do
    expect(Buildkite::TestCollector::OTel).not_to be_enabled

    example = run_sandboxed_example

    trace = Buildkite::TestCollector.uploader.traces.fetch(example.id)
    expect(trace.as_hash).not_to have_key(:trace_id)
  ensure
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
  end
end
