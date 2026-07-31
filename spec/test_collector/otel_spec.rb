# frozen_string_literal: true

require "opentelemetry/sdk"

RSpec.describe Buildkite::TestCollector::OTel do
  it "starts the execution as a root when another span is active" do
    agent_trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    agent_span_id = "00f067aa0ba902b7"
    fake_env("TRACEPARENT", "00-#{agent_trace_id}-#{agent_span_id}-01")
    fake_env("TRACESTATE", "vendor=value,buildkite=agent")

    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    tracer = provider.tracer("correlation-test")

    described_class.instance_variable_set(:@tracer, tracer)
    allow(SecureRandom).to receive(:uuid_v7) { "execution-id" }

    tracer.in_span("ambient") do
      execution_span, external_id = described_class.start_test_span
      expect(external_id).to eq("execution-id")
      described_class.with_test_span(execution_span) do
        tracer.in_span("child") { nil }
      end
      described_class.finish_test_span(execution_span, result: "passed")
    end
    provider.force_flush

    execution_span = exporter.finished_spans.find { |span| span.name == "test.execution" }
    child_span = exporter.finished_spans.find { |span| span.name == "child" }
    ambient_span = exporter.finished_spans.find { |span| span.name == "ambient" }

    expect(execution_span.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
    expect(child_span.parent_span_id).to eq(execution_span.span_id)
    expect(child_span.trace_id).to eq(execution_span.trace_id)
    expect(ambient_span.trace_id).not_to eq(execution_span.trace_id)
    expect(execution_span.attributes.fetch("execution.externalId")).to eq("execution-id")
    expect(child_span.attributes).not_to have_key("execution.externalId")

    expect(execution_span.links.length).to eq(1)
    link_context = execution_span.links.first.span_context
    expect(link_context.trace_id.unpack1("H*")).to eq(agent_trace_id)
    expect(link_context.span_id.unpack1("H*")).to eq(agent_span_id)
    expect(link_context.tracestate.to_s).to eq("vendor=value,buildkite=agent")
    expect(execution_span.trace_id).not_to eq(link_context.trace_id)
  ensure
    described_class.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "omits the Agent link when trace context is missing or malformed" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    described_class.instance_variable_set(:@tracer, provider.tracer("invalid-link-test"))

    fake_env("TRACEPARENT", nil)
    fake_env("TRACESTATE", nil)
    missing_span, = described_class.start_test_span
    described_class.finish_test_span(missing_span, result: "passed")

    fake_env("TRACEPARENT", "not-a-traceparent")
    fake_env("TRACESTATE", "vendor=value")
    malformed_span, = described_class.start_test_span
    described_class.finish_test_span(malformed_span, result: "passed")
    provider.force_flush

    expect(exporter.finished_spans.map(&:links)).to all(be_empty)
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

  it "omits the upload correlation ID when the span is not sampled" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
      sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF,
    )
    described_class.instance_variable_set(:@tracer, provider.tracer("unsampled-test"))

    span, external_id = described_class.start_test_span

    expect(span).not_to be_nil
    expect(external_id).to be_nil
  ensure
    described_class.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "records failed and skipped test outcomes" do
    span_class = Struct.new(:attributes, :status, :finished) do
      def set_attribute(key, value)
        attributes[key] = value
      end

      def finish
        self.finished = true
      end
    end

    failed_span = span_class.new({})
    described_class.finish_test_span(
      failed_span,
      result: "failed",
      tags: { "component" => "checkout" },
    )
    skipped_span = span_class.new({})
    described_class.finish_test_span(skipped_span, result: "skipped")

    expect(failed_span.attributes).to include(
      "test.case.result.status" => "fail",
      "buildkite.test.execution.tag.component" => "checkout",
    )
    expect(failed_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(failed_span.finished).to be(true)
    expect(skipped_span.attributes.fetch("buildkite.test.case.result.status")).to eq("skipped")
    expect(skipped_span.attributes).not_to have_key("test.case.result.status")
    expect(skipped_span.status).to be_nil
    expect(skipped_span.finished).to be(true)
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

  it "builds job, run, and VCS exporter metadata" do
    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_BUILD_ID", "build-id")
    job_id = "019c8d97-f9ad-75a5-8173-dc6c1b54b901"
    fake_env("BUILDKITE_JOB_ID", job_id)
    fake_env("BUILDKITE_BUILD_URL", "https://buildkite.com/acme/test/builds/1")
    fake_env("BUILDKITE_PIPELINE_SLUG", "test-pipeline")
    fake_env("BUILDKITE_BRANCH", "main")
    fake_env("BUILDKITE_COMMIT", "abc123")
    fake_env("BUILDKITE_TAG", nil)

    run_env = { "key" => "test-run-id" }
    headers = described_class.send(:request_headers, run_env, nil)
    attributes = described_class.send(:resource_attributes, run_env)

    expect(headers.fetch("Buildkite-Test-Job-ID")).to eq(job_id)
    expect(attributes).to include(
      "buildkite.test.run.key" => "test-run-id",
      "buildkite.job.id" => job_id,
      "cicd.pipeline.run.id" => "build-id",
      "cicd.pipeline.task.run.id" => job_id,
      "cicd.pipeline.run.url.full" => "https://buildkite.com/acme/test/builds/1",
      "cicd.pipeline.name" => "test-pipeline",
      "vcs.ref.head.revision" => "abc123",
      "vcs.ref.head.name" => "main",
      "vcs.ref.type" => "branch",
    )
    expect(attributes).not_to have_key("buildkite.test.run.id")
  end

  it "uses tag names for Buildkite tag refs" do
    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_TAG", "v3.0.0")

    tag_attributes = described_class.send(:resource_attributes, { "key" => "run-key" })
    expect(tag_attributes).to include(
      "vcs.ref.head.name" => "v3.0.0",
      "vcs.ref.type" => "tag",
    )
  end
end
