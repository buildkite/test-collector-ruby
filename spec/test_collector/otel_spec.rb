# frozen_string_literal: true

# The OpenTelemetry gems only ship on Ruby 3.3 and newer.
if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3")
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
end
