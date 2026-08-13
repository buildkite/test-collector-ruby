# frozen_string_literal: true

require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"

RSpec.describe Buildkite::TestCollector::OTel do
  it "starts the execution as a root when another span is active" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    tracer = provider.tracer("correlation-test")

    described_class.instance_variable_set(:@tracer, tracer)

    tracer.in_span("ambient") do
      execution_span, trace_id = described_class.start_test_span
      expect(trace_id).to eq(execution_span.context.hex_trace_id)
      described_class.with_test_span(execution_span) do
        tracer.in_span("child") { nil }
      end
      described_class.finish_test_span(execution_span)
    end
    provider.force_flush

    execution_span = exporter.finished_spans.find { |span| span.name == "test.execution" }
    child_span = exporter.finished_spans.find { |span| span.name == "child" }
    ambient_span = exporter.finished_spans.find { |span| span.name == "ambient" }

    expect(execution_span.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
    expect(child_span.parent_span_id).to eq(execution_span.span_id)
    expect(child_span.trace_id).to eq(execution_span.trace_id)
    expect(ambient_span.trace_id).not_to eq(execution_span.trace_id)
  ensure
    described_class.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "fails open when starting a span fails" do
    tracer = double("OpenTelemetry tracer")
    allow(tracer).to receive(:start_span).and_raise("start failed")
    described_class.instance_variable_set(:@tracer, tracer)

    expect { expect(described_class.start_test_span).to eq([nil, nil]) }
      .to output(/Could not start OpenTelemetry test span/).to_stderr
  ensure
    described_class.instance_variable_set(:@tracer, nil)
  end

  it "still reports the trace ID when the span is not sampled" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
      sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF,
    )
    described_class.instance_variable_set(:@tracer, provider.tracer("unsampled-test"))

    span, trace_id = described_class.start_test_span

    expect(span).not_to be_nil
    expect(trace_id).to eq(span.context.hex_trace_id)
  ensure
    described_class.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "records what the test was and how it went" do
    span_class = Struct.new(:attributes, :status, :ended) do
      def set_attribute(key, value)
        attributes[key] = value
      end

      def finish
        self.ended = true
      end
    end
    described = Struct.new(:otel_attributes, :otel_result)

    failed = span_class.new({})
    described_class.finish_test_span(
      failed,
      test: described.new({ "test.case.name" => "adds up", "code.line.number" => nil }, "failed"),
    )
    skipped = span_class.new({})
    described_class.finish_test_span(skipped, test: described.new({}, "skipped"))

    expect(failed.attributes).to eq(
      "test.case.name" => "adds up",
      "test.case.result.status" => "fail",
    )
    expect(failed.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(failed.ended).to be(true)
    expect(skipped.attributes.fetch("test.case.result.status")).to eq("skipped")
    expect(skipped.status).to be_nil
    expect(skipped.ended).to be(true)
  end

  it "reports how long the finished span says the test took" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    described_class.instance_variable_set(:@tracer, provider.tracer("duration-test"))

    span, = described_class.start_test_span
    sleep 0.01
    duration = described_class.finish_test_span(span)

    data = span.to_span_data
    expect(duration).to eq((data.end_timestamp - data.start_timestamp) / 1_000_000_000.0)
    expect(duration).to be > 0.01
  ensure
    described_class.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "reports no duration for a span it cannot read" do
    span = double("OpenTelemetry span")
    allow(span).to receive(:finish)

    expect(described_class.finish_test_span(span)).to be_nil
  end

  it "finishes the span even when the test cannot be described" do
    span = double("OpenTelemetry span")
    allow(span).to receive(:finish)
    test = double("test")
    allow(test).to receive(:otel_attributes).and_raise("no metadata for you")

    expect { described_class.finish_test_span(span, test: test) }
      .to output(/Could not describe OpenTelemetry test span/).to_stderr
    expect(span).to have_received(:finish).once
  end

  it "asks nothing of the test when there is no span" do
    # A strict double raises on any message it wasn't told to expect.
    test = double("test")

    expect { described_class.finish_test_span(nil, test: test) }.not_to raise_error
  end

  it "does not raise when shutting down its processor fails" do
    processor = double("OpenTelemetry processor")
    allow(processor).to receive(:shutdown).and_raise("shutdown failed")
    described_class.instance_variable_set(:@processor, processor)

    expect { described_class.shutdown }.not_to raise_error
    expect(described_class).not_to be_enabled
  ensure
    described_class.instance_variable_set(:@processor, nil)
    described_class.instance_variable_set(:@tracer, nil)
  end

  it "fails open when an OpenTelemetry dependency cannot be loaded" do
    allow(described_class).to receive(:require).and_call_original
    allow(described_class).to receive(:require)
      .with("opentelemetry/sdk")
      .and_raise(LoadError, "cannot load OpenTelemetry SDK")

    expect do
      described_class.configure!(
        endpoint: "https://example.invalid/v1/traces",
        run_env: { "key" => "run-123" },
      )
    end.to output(/OpenTelemetry span export disabled: LoadError/).to_stderr
    expect(described_class).not_to be_enabled
  end

  it "sends the run key and token as request headers" do
    headers = described_class.send(:request_headers, { "key" => "test-run-id" }, "suite-token")

    expect(headers).to eq(
      "Buildkite-Test-Run-Key" => "test-run-id",
      "Authorization" => %(Token token="suite-token"),
    )
  end

  it "exports through the suite's own provider without taking it over" do
    original = OpenTelemetry.tracer_provider
    suite_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(suite_exporter)
    )
    OpenTelemetry.tracer_provider = provider

    buildkite_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new) { buildkite_exporter }
    described_class.configure!(endpoint: "https://example.invalid/v1/traces")

    tracer = provider.tracer("suite")
    tracer.in_span("before-shutdown") { nil }
    provider.force_flush

    expect(OpenTelemetry.tracer_provider).to equal(provider)
    expect(buildkite_exporter.finished_spans.map(&:name)).to include("before-shutdown")
    expect(suite_exporter.finished_spans.map(&:name)).to include("before-shutdown")

    described_class.shutdown
    tracer.in_span("after-shutdown") { nil }
    provider.force_flush

    # Our processor goes quiet, the suite's keeps working.
    expect(buildkite_exporter.finished_spans.map(&:name)).not_to include("after-shutdown")
    expect(suite_exporter.finished_spans.map(&:name)).to include("after-shutdown")
  ensure
    described_class.shutdown
    provider&.shutdown
    OpenTelemetry.tracer_provider = original
  end

  it "leaves instrumentation alone when the suite runs its own OpenTelemetry" do
    original = OpenTelemetry.tracer_provider
    OpenTelemetry.tracer_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    registry = OpenTelemetry::Instrumentation.registry
    allow(registry).to receive(:install_all)
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new) do
      OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    end

    described_class.configure!(endpoint: "https://example.invalid/v1/traces")

    expect(described_class).to be_enabled
    expect(registry).not_to have_received(:install_all)
  ensure
    described_class.shutdown
    OpenTelemetry.tracer_provider = original
  end

  it "installs every available instrumentation" do
    registry = OpenTelemetry::Instrumentation.registry
    allow(registry).to receive(:install_all)
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new) do
      OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    end

    described_class.configure!(endpoint: "https://example.invalid/v1/traces")

    expect(registry).to have_received(:install_all)
  ensure
    described_class.shutdown
  end
end
