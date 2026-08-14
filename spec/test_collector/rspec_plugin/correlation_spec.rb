# frozen_string_literal: true

require "opentelemetry/sdk"
require "rspec/core/sandbox"

RSpec.describe "RSpec execution and OpenTelemetry correlation" do
  # Runs one example through the collector's real around hook. Sandboxed, so
  # registering that hook doesn't disturb the suite running this test.
  def run_sandboxed_example(metadata = {}, &block)
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec.rb"

      group = RSpec.describe("Correlated group") do
        it("passes", metadata, &(block || proc { nil }))
      end
      group.run(RSpec.configuration.reporter)
      group.examples.first
    end
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

  it "sends no trace ID when OpenTelemetry is off" do
    expect(Buildkite::TestCollector::OTel).not_to be_enabled

    example = run_sandboxed_example

    trace = Buildkite::TestCollector.uploader.traces.fetch(example.id)
    expect(trace.as_hash).not_to have_key(:trace_id)
  ensure
    Buildkite::TestCollector.uploader.traces.delete(example&.id)
  end
end
