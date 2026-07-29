# frozen_string_literal: true

require "open3"
require "opentelemetry/sdk"

RSpec.describe "RSpec execution and OpenTelemetry correlation" do
  it "uses one external ID for the upload and execution span without copying it to children" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "correlation.json")
      fixture_path = File.join(directory, "correlation_spec.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"
        require "opentelemetry/sdk"

        class RecordingOTelTracer
          Span = Struct.new(:name, :span_id, :parent_span_id, :trace_id, :attributes, :status) do
            def set_attribute(key, value)
              attributes[key] = value
            end

            def status=(value)
              self[:status] = value.code
            end
          end

          attr_reader :spans

          def initialize
            @spans = []
            @active_spans = []
          end

          def in_span(name, attributes: {}, kind: nil)
            parent = @active_spans.last
            span_id = format("%016x", @spans.length + 1)
            trace_id = parent ? parent.trace_id : format("%032x", @spans.length + 1)
            span = Span.new(name, span_id, parent ? parent.span_id : "", trace_id, attributes)
            @spans << span
            @active_spans << span
            yield span
          ensure
            @active_spans.pop
          end
        end

        Buildkite::TestCollector.configure(hook: :rspec, tracing_enabled: false)

        external_id = "019c8d97-f9ad-75a5-8173-dc6c1b54b901"
        $generated_external_ids = 0
        Buildkite::TestCollector::UUID.define_singleton_method(:v7) do
          $generated_external_ids += 1
          external_id
        end

        $recording_otel_tracer = RecordingOTelTracer.new
        Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, true)
        Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, $recording_otel_tracer)
        Buildkite::TestCollector::OTel.define_singleton_method(:force_flush) { nil }
        Buildkite::TestCollector::OTel.define_singleton_method(:shutdown) do
          instance_variable_set(:@enabled, false)
        end

        at_exit do
          result = {
            generated_external_ids: $generated_external_ids,
            uploads: $uploads,
            spans: $recording_otel_tracer.spans.map do |span|
              {
                name: span.name,
                span_id: span.span_id,
                parent_span_id: span.parent_span_id,
                trace_id: span.trace_id,
                attributes: span.attributes,
                status: span.status,
              }
            end,
          }
          File.write(ENV.fetch("CORRELATION_RESULT_PATH"), JSON.generate(result))
        end

        Buildkite::TestCollector::Uploader.define_singleton_method(:upload) do |traces|
          $uploads = traces.map(&:as_hash)
          nil
        end

        RSpec.describe "instrumented example" do
          it "makes an auto-instrumented span" do
            Buildkite::TestCollector.tag_execution("component", "checkout")
            $recording_otel_tracer.in_span("http.request") { nil }
          end
        end
      RUBY

      rspec_path = Gem.bin_path("rspec-core", "rspec")
      _stdout, stderr, status = Open3.capture3(
        { "CORRELATION_RESULT_PATH" => result_path },
        RbConfig.ruby,
        "-I#{lib_path}",
        rspec_path,
        fixture_path,
      )

      expect(status).to be_success, stderr

      result = JSON.parse(File.read(result_path))
      expect(result.fetch("generated_external_ids")).to eq(1)
      expect(result.fetch("uploads").length).to eq(1)
      expect(result.dig("uploads", 0, "external_id")).to eq("019c8d97-f9ad-75a5-8173-dc6c1b54b901")

      expect(result.fetch("spans").length).to eq(2)
      execution_span, child_span = result.fetch("spans")
      expect(execution_span.fetch("name")).to eq("test.execution")
      expect(execution_span.dig("attributes", "execution.externalId")).to eq("019c8d97-f9ad-75a5-8173-dc6c1b54b901")
      expect(execution_span.dig("attributes", "test.case.name")).to eq("instrumented example makes an auto-instrumented span")
      expect(execution_span.dig("attributes", "test.suite.name")).to eq("instrumented example")
      expect(execution_span.dig("attributes", "test.case.result.status")).to eq("pass")
      expect(execution_span.dig("attributes", "code.file.path")).to end_with("correlation_spec.rb")
      expect(execution_span.dig("attributes", "code.line.number")).to be_a(Integer)
      expect(execution_span.dig("attributes", "buildkite.test.case.id")).to include("correlation_spec.rb")
      expect(execution_span.dig("attributes", "buildkite.test.runner.name")).to eq("rspec")
      expect(execution_span.dig("attributes", "buildkite.test.runner.version")).to eq(RSpec::Core::Version::STRING)
      expect(execution_span.dig("attributes", "buildkite.test.execution.tag.component")).to eq("checkout")

      expect(child_span.fetch("name")).to eq("http.request")
      expect(child_span.fetch("parent_span_id")).to eq(execution_span.fetch("span_id"))
      expect(child_span.fetch("trace_id")).to eq(execution_span.fetch("trace_id"))
      expect(child_span.fetch("attributes")).not_to have_key("execution.externalId")
      expect(child_span.fetch("attributes")).not_to have_key("buildkite.test.execution.tag.component")
    end
  end

  it "starts the execution as a root when another span is active" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    tracer = provider.tracer("correlation-test")

    Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, true)
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, tracer)

    tracer.in_span("ambient") do
      Buildkite::TestCollector::OTel.in_test_span(
        name: "test.execution",
        external_id: "execution-id",
      ) do
        tracer.in_span("child") { nil }
      end
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
    Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, false)
    Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "records failed and skipped test outcomes" do
    span_class = Struct.new(:attributes, :status) do
      def set_attribute(key, value)
        attributes[key] = value
      end
    end

    failed_span = span_class.new({})
    Buildkite::TestCollector::OTel.record_test_result(
      failed_span,
      result: "failed",
      tags: { "component" => "checkout" },
    )
    skipped_span = span_class.new({})
    Buildkite::TestCollector::OTel.record_test_result(
      skipped_span,
      result: "skipped",
    )

    expect(failed_span.attributes).to include(
      "test.case.result.status" => "fail",
      "buildkite.test.execution.tag.component" => "checkout",
    )
    expect(failed_span.status.code).to eq(OpenTelemetry::Trace::Status::ERROR)
    expect(skipped_span.attributes.fetch("test.case.result.status")).to eq("skipped")
    expect(skipped_span.status).to be_nil
  end

  it "builds run and VCS resource attributes" do
    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_BUILD_ID", "build-id")
    fake_env("BUILDKITE_PIPELINE_SLUG", "test-pipeline")
    fake_env("BUILDKITE_TAG", nil)
    fake_env("GITHUB_RUN_ID", nil)
    fake_env("CIRCLE_WORKFLOW_ID", nil)
    fake_env("CI_NAME", nil)

    attributes = Buildkite::TestCollector::OTel.send(
      :resource_attributes,
      {
        "key" => "test-run-id",
        "url" => "https://buildkite.com/acme/test/builds/1",
        "branch" => "main",
        "commit_sha" => "abc123",
      }
    )

    expect(attributes).to include(
      "buildkite.test.run.id" => "test-run-id",
      "cicd.pipeline.run.id" => "build-id",
      "cicd.pipeline.run.url.full" => "https://buildkite.com/acme/test/builds/1",
      "cicd.pipeline.name" => "test-pipeline",
      "vcs.ref.head.revision" => "abc123",
      "vcs.ref.head.name" => "main",
      "vcs.ref.type" => "branch",
    )
  end
end
