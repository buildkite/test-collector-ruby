# frozen_string_literal: true

require "opentelemetry/sdk"

RSpec.describe Buildkite::TestCollector::OTel do
  it "starts the execution as a root when another span is active" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    tracer = provider.tracer("correlation-test")

    described_class.instance_variable_set(:@enabled, true)
    described_class.instance_variable_set(:@tracer, tracer)

    tracer.in_span("ambient") do
      execution_span = described_class.start_test_span(
        name: "test.execution",
        external_id: "execution-id",
      )
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
  ensure
    described_class.instance_variable_set(:@enabled, false)
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

  it "does not raise when flushing or shutting down its processor fails" do
    processor = double("OpenTelemetry processor")
    allow(processor).to receive(:force_flush).and_raise("flush failed")
    allow(processor).to receive(:shutdown).and_raise("shutdown failed")
    described_class.instance_variable_set(:@enabled, true)
    described_class.instance_variable_set(:@processor, processor)

    expect { described_class.force_flush }.not_to raise_error
    expect { described_class.shutdown }.not_to raise_error
    expect(described_class).not_to be_enabled
  ensure
    described_class.instance_variable_set(:@enabled, false)
    described_class.instance_variable_set(:@processor, nil)
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

  it "builds run and VCS resource attributes" do
    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_BUILD_ID", "build-id")
    fake_env("BUILDKITE_PIPELINE_SLUG", "test-pipeline")
    fake_env("BUILDKITE_TAG", nil)
    fake_env("GITHUB_RUN_ID", nil)
    fake_env("CIRCLE_WORKFLOW_ID", nil)
    fake_env("CI_NAME", nil)

    attributes = described_class.send(
      :resource_attributes,
      {
        "key" => "test-run-id",
        "url" => "https://buildkite.com/acme/test/builds/1",
        "branch" => "main",
        "commit_sha" => "abc123",
      }
    )

    expect(attributes).to include(
      "buildkite.test.run.key" => "test-run-id",
      "cicd.pipeline.run.id" => "build-id",
      "cicd.pipeline.run.url.full" => "https://buildkite.com/acme/test/builds/1",
      "cicd.pipeline.name" => "test-pipeline",
      "vcs.ref.head.revision" => "abc123",
      "vcs.ref.head.name" => "main",
      "vcs.ref.type" => "branch",
    )
    expect(attributes).not_to have_key("buildkite.test.run.id")
  end

  it "uses tag names for Buildkite tag refs and omits Codeship pull request URLs" do
    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_BUILD_ID", "build-id")
    fake_env("BUILDKITE_TAG", "v3.0.0")
    fake_env("BUILDKITE_ANALYTICS_URL", nil)
    fake_env("GITHUB_RUN_ID", nil)
    fake_env("CIRCLE_WORKFLOW_ID", nil)
    fake_env("CI_NAME", nil)

    tag_attributes = described_class.send(:resource_attributes, { "branch" => "main" })
    expect(tag_attributes).to include(
      "vcs.ref.head.name" => "v3.0.0",
      "vcs.ref.type" => "tag",
    )

    fake_env("BUILDKITE_BUILD_ID", nil)
    codeship_attributes = described_class.send(
      :resource_attributes,
      {
        "CI" => "codeship",
        "url" => "https://github.com/acme/repo/pull/123",
      }
    )
    expect(codeship_attributes).not_to have_key("cicd.pipeline.run.url.full")
  end
end
