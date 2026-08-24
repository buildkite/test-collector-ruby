# frozen_string_literal: true

require "opentelemetry/sdk"
require "rspec/core/sandbox"
require "buildkite/test_collector/rspec_plugin/reporter"

RSpec.describe "RSpec OTLP-only submission" do
  # Sandboxed so the collector's hooks don't disturb this suite. group.run
  # doesn't fire before(:suite), so the formatter is added directly.
  def run_sandboxed_example(metadata = {}, &block)
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"
      config.add_formatter Buildkite::TestCollector::RSpecPlugin::Reporter

      group = RSpec.describe("OTLP-only group") do
        it("does something", metadata, &(block || proc { nil }))
      end
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
  end

  around do |test|
    original_otel_only = Buildkite::TestCollector.otel_only
    Buildkite::TestCollector.otel_only = true

    @exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    @provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    @provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(@exporter)
    )
    Buildkite::TestCollector::OTel.instance_variable_set(
      :@tracer, @provider.tracer("otel-only-test")
    )

    test.run
  ensure
    Buildkite::TestCollector.otel_only = original_otel_only
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    @provider&.shutdown
  end

  def finished_test_span
    @provider.force_flush
    @exporter.finished_spans.find { |span| span.name == "test.execution" }
  end

  it "describes the whole execution on the span and uploads no JSON" do
    expect(Buildkite::TestCollector::Tracer).not_to receive(:new)
    expect(Buildkite::TestCollector).not_to receive(:enable_tracing!)

    example = run_sandboxed_example { nil }
    span = finished_test_span

    expect(span).not_to be_nil
    expect(span.attributes).to include(
      "buildkite.execution.via" => "otlp",
      "buildkite.test.scope" => "OTLP-only group",
      "buildkite.test.name" => "does something",
      "test.suite.name" => "OTLP-only group",
      "test.case.name" => "OTLP-only group does something",
      "test.case.result.status" => "pass",
    )
    expect(span.attributes.fetch("code.file.path")).to end_with("otel_only_spec.rb")
    expect(span.attributes.fetch("code.line.number")).to be_an(Integer)
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)

    # No JSON upload is prepared: the legacy uploader never sees the example.
    expect(Buildkite::TestCollector.uploader.traces).not_to have_key(example.id)
  end

  it "records the failure as span status and exception events" do
    run_sandboxed_example { raise "boom happened" }
    span = finished_test_span

    expect(span.attributes).to include("test.case.result.status" => "fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(span.status.description).to include("boom happened")

    exception_event = span.events.find { |event| event.name == "exception" }
    expect(exception_event.attributes.fetch("exception.message")).to include("boom happened")
    expect(exception_event.attributes.fetch("exception.stacktrace")).to be_a(String)
  end

  it "marks a pending example as skipped" do
    run_sandboxed_example(skip: false) do
      pending("not done yet")
      raise "expected to fail"
    end
    span = finished_test_span

    expect(span.attributes).to include(
      "test.case.result.status" => "skipped",
    )
  end

  it "classifies a failure raised by an inner around hook after the example ran" do
    example = RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"
      config.add_formatter Buildkite::TestCollector::RSpecPlugin::Reporter

      # Registered after the collector's hook, so its exception escapes
      # through the collector while example.exception is still nil.
      config.around(:each) do |inner|
        inner.run
        raise "hook boom"
      end

      group = RSpec.describe("OTLP-only group") do
        it("does something") {}
      end
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
    span = finished_test_span

    expect(example.execution_result.status).to eq(:failed)
    expect(span.attributes).to include("test.case.result.status" => "fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(span.status.description).to include("hook boom")
    exception_event = span.events.find { |event| event.name == "exception" }
    expect(exception_event.attributes.fetch("exception.message")).to include("hook boom")
  end

  it "classifies a failure raised by an outer around hook after the example ran" do
    example = RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new

      # Registered before the collector's hook, so it wraps it and raises
      # after the collector has fully unwound.
      config.around(:each) do |inner|
        inner.run
        raise "outer boom"
      end

      load "buildkite/test_collector/library_hooks/rspec.rb"
      config.add_formatter Buildkite::TestCollector::RSpecPlugin::Reporter

      group = RSpec.describe("OTLP-only group") do
        it("does something") {}
      end
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
    span = finished_test_span

    expect(example.execution_result.status).to eq(:failed)
    expect(span.attributes).to include("test.case.result.status" => "fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(span.status.description).to include("outer boom")
  end

  it "keeps an acknowledged-pending example skipped when a hook raises deliberately" do
    example = RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"
      config.add_formatter Buildkite::TestCollector::RSpecPlugin::Reporter

      # Scientist-style acknowledgement: pending plus a deliberate raise is
      # pending to RSpec (exit 0), not failed.
      config.around(:each) do |inner|
        inner.run
        pending("acknowledged mismatch")
        raise "deliberate failure to keep RSpec's pending semantics"
      end

      group = RSpec.describe("OTLP-only group") do
        it("does something") {}
      end
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
    span = finished_test_span

    expect(example.execution_result.status).to eq(:pending)
    expect(span.attributes).to include("test.case.result.status" => "skipped")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)
  end

  it "classifies a pending example that unexpectedly passes as failed" do
    example = run_sandboxed_example do
      pending("will be fixed one day")
      expect(true).to eq(true)
    end
    span = finished_test_span

    expect(example.execution_result.status).to eq(:failed)
    expect(span.attributes).to include("test.case.result.status" => "fail")
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
  end

  it "finishes spans through the reporter that before(:suite) registers" do
    Buildkite::TestCollector.instance_variable_set(:@otel_options, nil)

    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"

      group = RSpec.describe("OTLP-only group") do
        it("does something") {}
      end
      config.with_suite_hooks { group.run(RSpec.configuration.reporter) }
    end
    span = finished_test_span

    expect(span).not_to be_nil
    expect(span.attributes).to include("test.case.result.status" => "pass")
  end

  it "turns annotations into span events and tags into span attributes" do
    run_sandboxed_example do
      Buildkite::TestCollector.annotate("checkpoint reached")
      Buildkite::TestCollector.tag_execution("team", "platform")
    end
    span = finished_test_span

    annotation = span.events.find { |event| event.name == "test.annotation" }
    expect(annotation.attributes).to eq("buildkite.annotation" => "checkpoint reached")
    expect(span.attributes).to include("buildkite.tag.team" => "platform")
  end
end
