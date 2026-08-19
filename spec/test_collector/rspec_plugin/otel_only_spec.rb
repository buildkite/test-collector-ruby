# frozen_string_literal: true

require "opentelemetry/sdk"
require "rspec/core/sandbox"
require "buildkite/test_collector/rspec_plugin/otel_only"

RSpec.describe "RSpec OTLP-only submission" do
  # Runs one example through the OTLP-only around hook. Sandboxed, so
  # registering that hook doesn't disturb the suite running this test.
  def run_sandboxed_example(metadata = {}, &block)
    RSpec::Core::Sandbox.sandboxed do |config|
      config.output_stream = StringIO.new
      load "buildkite/test_collector/library_hooks/rspec_otel_only.rb"

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
    example = run_sandboxed_example { nil }
    span = finished_test_span

    expect(span).not_to be_nil
    expect(span.attributes).to include(
      "execution.via" => "otlp",
      "test.scope" => "OTLP-only group",
      "test.name" => "does something",
      "test.suite.name" => "OTLP-only group",
      "test.case.name" => "OTLP-only group does something",
      "buildkite.test.result" => "passed",
      "test.case.result.status" => "pass",
    )
    expect(span.attributes.fetch("code.file.path")).to end_with("otel_only_spec.rb")
    expect(span.attributes.fetch("buildkite.test.file_name")).to end_with("otel_only_spec.rb")
    expect(span.attributes.fetch("buildkite.test.location")).to match(/otel_only_spec\.rb:\d+\z/)
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::UNSET)

    # No JSON upload is prepared: the legacy uploader never sees the example.
    expect(Buildkite::TestCollector.uploader.traces).not_to have_key(example.id)
  end

  it "records the failure on the span" do
    run_sandboxed_example { raise "boom happened" }
    span = finished_test_span

    expect(span.attributes).to include(
      "buildkite.test.result" => "failed",
      "test.case.result.status" => "fail",
      "buildkite.test.failure_reason" => "boom happened",
    )
    expanded = JSON.parse(span.attributes.fetch("buildkite.test.failure_expanded"))
    expect(expanded.first.fetch("expanded")).to eq(["boom happened"])
    expect(expanded.first.fetch("backtrace")).to be_an(Array)
    expect(span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)

    exception_event = span.events.find { |event| event.name == "exception" }
    expect(exception_event.attributes).to include("exception.message" => "boom happened")
  end

  it "marks a pending example as skipped" do
    run_sandboxed_example(skip: false) do
      pending("not done yet")
      raise "expected to fail"
    end
    span = finished_test_span

    expect(span.attributes).to include(
      "buildkite.test.result" => "skipped",
      "test.case.result.status" => "skipped",
    )
  end

  it "turns annotations into span events and tags into span attributes" do
    run_sandboxed_example do
      Buildkite::TestCollector.annotate("checkpoint reached")
      Buildkite::TestCollector.tag_execution("team", "platform")
    end
    span = finished_test_span

    annotation = span.events.find { |event| event.name == "test.annotation" }
    expect(annotation.attributes).to eq("buildkite.annotation" => "checkpoint reached")
    expect(span.attributes).to include("team" => "platform")
  end
end

RSpec.describe Buildkite::TestCollector::RSpecPlugin::OTelOnlyTrace do
  subject(:trace) do
    described_class.new(
      example,
      history: {},
      tags: tags,
      location_prefix: location_prefix,
    )
  end

  let(:example) { fake_example(file_path: "./spec/foo_spec.rb", status: :passed) }
  let(:tags) { nil }
  let(:location_prefix) { nil }

  describe "#otel_attributes" do
    it "carries the full execution details for server-side synthesis" do
      allow(example).to receive(:exception) { nil }

      expect(trace.otel_attributes).to eq(
        "execution.via" => "otlp",
        "test.scope" => "this is a fake example full description",
        "test.name" => "fake example name",
        "buildkite.test.location" => "./spec/foo_spec.rb:42",
        "buildkite.test.file_name" => "./spec/foo_spec.rb",
        "test.suite.name" => "this is a fake example full description",
        "test.case.name" => "this is a fake example full description",
        "code.file.path" => "./spec/foo_spec.rb",
        "code.line.number" => 42,
        "buildkite.test.result" => "passed",
      )
    end

    it "includes failure details as attributes" do
      allow(example).to receive(:exception) { StandardError.new("it broke") }
      trace.failure_reason = "it broke"
      trace.failure_expanded = [{ expanded: ["it broke"], backtrace: ["foo.rb:1"] }]

      expect(trace.otel_attributes).to include(
        "buildkite.test.result" => "failed",
        "buildkite.test.failure_reason" => "it broke",
        "buildkite.test.failure_expanded" =>
          %([{"expanded":["it broke"],"backtrace":["foo.rb:1"]}]),
      )
    end

    context "with execution tags" do
      let(:tags) { { "team" => "platform" } }

      it "includes them as span attributes" do
        allow(example).to receive(:exception) { nil }

        expect(trace.otel_attributes).to include("team" => "platform")
      end
    end

    context "when location_prefix is provided" do
      let(:location_prefix) { "some/prefix" }

      it "prefixes the file and location paths" do
        allow(example).to receive(:exception) { nil }

        expect(trace.otel_attributes).to include(
          "buildkite.test.file_name" => "some/prefix/spec/foo_spec.rb",
          "code.file.path" => "some/prefix/spec/foo_spec.rb",
          "buildkite.test.location" => "some/prefix/spec/foo_spec.rb:42",
        )
      end
    end
  end
end
