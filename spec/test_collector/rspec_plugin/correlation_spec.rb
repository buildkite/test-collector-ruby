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
          Span = Struct.new(:name, :span_id, :parent_span_id, :trace_id, :attributes, :status, :finished) do
            def set_attribute(key, value)
              attributes[key] = value
            end

            def status=(value)
              self[:status] = value.code
            end

            def finish
              self.finished = true
            end
          end

          attr_reader :spans

          def initialize
            @spans = []
          end

          def start_span(name, with_parent: nil, attributes: {}, kind: nil)
            parent = OpenTelemetry::Trace.current_span(with_parent)
            parent = nil unless parent.respond_to?(:trace_id)
            span_id = format("%016x", @spans.length + 1)
            trace_id = parent ? parent.trace_id : format("%032x", @spans.length + 1)
            span = Span.new(name, span_id, parent ? parent.span_id : "", trace_id, attributes)
            @spans << span
            span
          end

          def in_span(name, attributes: {}, kind: nil)
            span = start_span(name, attributes: attributes, kind: kind)
            OpenTelemetry::Trace.with_span(span) { yield span }
          ensure
            span&.finish
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
                finished: span.finished,
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
      expect(execution_span.fetch("finished")).to be(true)

      expect(child_span.fetch("name")).to eq("http.request")
      expect(child_span.fetch("parent_span_id")).to eq(execution_span.fetch("span_id"))
      expect(child_span.fetch("trace_id")).to eq(execution_span.fetch("trace_id"))
      expect(child_span.fetch("attributes")).not_to have_key("execution.externalId")
      expect(child_span.fetch("attributes")).not_to have_key("buildkite.test.execution.tag.component")
    end
  end

  it "runs and uploads the example when starting its OpenTelemetry span fails" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "start-failure.json")
      fixture_path = File.join(directory, "start_failure_spec.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"

        Buildkite::TestCollector.configure(hook: :rspec, tracing_enabled: false)

        raising_tracer = Object.new
        raising_tracer.define_singleton_method(:start_span) do |**_options|
          raise "customer processor failed"
        end
        Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, true)
        Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, raising_tracer)
        Buildkite::TestCollector::OTel.define_singleton_method(:force_flush) { nil }
        Buildkite::TestCollector::OTel.define_singleton_method(:shutdown) do
          instance_variable_set(:@enabled, false)
        end

        at_exit do
          File.write(
            ENV.fetch("START_FAILURE_RESULT_PATH"),
            JSON.generate(body_ran: $body_ran, uploads: $uploads),
          )
        end

        Buildkite::TestCollector::Uploader.define_singleton_method(:upload) do |traces|
          $uploads = traces.map(&:as_hash)
          nil
        end

        RSpec.describe "start failure" do
          it "still runs" do
            $body_ran = true
          end
        end
      RUBY

      rspec_path = Gem.bin_path("rspec-core", "rspec")
      _stdout, stderr, status = Open3.capture3(
        { "START_FAILURE_RESULT_PATH" => result_path },
        RbConfig.ruby,
        "-I#{lib_path}",
        rspec_path,
        fixture_path,
      )

      expect(status).to be_success, stderr
      result = JSON.parse(File.read(result_path))
      expect(result.fetch("body_ran")).to be(true)
      expect(result.fetch("uploads").length).to eq(1)
      expect(result.dig("uploads", 0)).not_to have_key("external_id")
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
      execution_span = Buildkite::TestCollector::OTel.start_test_span(
        name: "test.execution",
        external_id: "execution-id",
      )
      Buildkite::TestCollector::OTel.with_test_span(execution_span) do
        tracer.in_span("child") { nil }
      end
      Buildkite::TestCollector::OTel.finish_test_span(execution_span, result: "passed")
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

  it "uses RSpec's final result after outer hooks unwind" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "final-result.json")
      fixture_path = File.join(directory, "final_result_spec.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "rspec/core"
        require "buildkite/test_collector"
        require "opentelemetry/sdk"

        RSpec.configure do |config|
          config.around(:each) do |example|
            example.run
            raise "failure after collector hook returned"
          end
        end

        Buildkite::TestCollector.configure(hook: :rspec, tracing_enabled: false)

        exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
        provider = OpenTelemetry::SDK::Trace::TracerProvider.new
        provider.add_span_processor(processor)
        Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, true)
        Buildkite::TestCollector::OTel.instance_variable_set(
          :@tracer,
          provider.tracer("final-result-test"),
        )
        Buildkite::TestCollector::OTel.define_singleton_method(:force_flush) { provider.force_flush }
        Buildkite::TestCollector::OTel.define_singleton_method(:shutdown) do
          provider.force_flush
          span = exporter.finished_spans.find { |item| item.name == "test.execution" }
          File.write(
            ENV.fetch("FINAL_RESULT_PATH"),
            JSON.generate(
              result: span.attributes["test.case.result.status"],
              status: span.status.code,
            ),
          )
          instance_variable_set(:@enabled, false)
        end

        RSpec.describe "outer hook failure" do
          it("passes its own body") { expect(true).to be(true) }
        end
      RUBY

      rspec_path = Gem.bin_path("rspec-core", "rspec")
      _stdout, _stderr, status = Open3.capture3(
        { "FINAL_RESULT_PATH" => result_path },
        RbConfig.ruby,
        "-I#{lib_path}",
        rspec_path,
        fixture_path,
      )

      expect(status).not_to be_success
      result = JSON.parse(File.read(result_path))
      expect(result.fetch("result")).to eq("fail")
      expect(result.fetch("status")).to eq(OpenTelemetry::Trace::Status::ERROR)
    end
  end

  it "adds its exporter to an existing provider without owning that provider" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "provider.json")
      fixture_path = File.join(directory, "provider.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"
        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"

        customer_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        customer_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(customer_exporter)
        customer_resource = OpenTelemetry::SDK::Resources::Resource.create(
          "service.name" => "customer-service",
        )
        provider = OpenTelemetry::SDK::Trace::TracerProvider.new(resource: customer_resource)
        provider.add_span_processor(customer_processor)
        OpenTelemetry.tracer_provider = provider

        class CountingExporter < OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter
          attr_reader :shutdown_calls

          def initialize
            super
            @shutdown_calls = 0
          end

          def shutdown(timeout: nil)
            @shutdown_calls += 1
            super
          end
        end

        buildkite_exporter = CountingExporter.new
        OpenTelemetry::Exporter::OTLP::Exporter.define_singleton_method(:new) do |**_options|
          buildkite_exporter
        end

        Buildkite::TestCollector::OTel.configure!(
          endpoint: "https://example.invalid/v1/traces",
          run_env: { "key" => "run-123" },
        )

        tracer = OpenTelemetry.tracer_provider.tracer("customer")
        tracer.in_span("before-buildkite-shutdown") { nil }
        Buildkite::TestCollector::OTel.force_flush

        buildkite_span = buildkite_exporter.finished_spans.find do |span|
          span.name == "before-buildkite-shutdown"
        end
        customer_span = customer_exporter.finished_spans.find do |span|
          span.name == "before-buildkite-shutdown"
        end

        Buildkite::TestCollector::OTel.shutdown
        tracer.in_span("after-buildkite-shutdown") { nil }

        customer_continued = customer_exporter.finished_spans.any? do |span|
          span.name == "after-buildkite-shutdown"
        end
        buildkite_stopped = buildkite_exporter.finished_spans.none? do |span|
          span.name == "after-buildkite-shutdown"
        end
        provider.shutdown

        File.write(
          ENV.fetch("PROVIDER_RESULT_PATH"),
          JSON.generate(
            same_provider: OpenTelemetry.tracer_provider.equal?(provider),
            buildkite_resource: buildkite_span.resource.attribute_enumerator.to_h,
            customer_resource: customer_span.resource.attribute_enumerator.to_h,
            customer_continued: customer_continued,
            buildkite_stopped: buildkite_stopped,
            buildkite_shutdown_calls: buildkite_exporter.shutdown_calls,
          ),
        )
      RUBY

      stdout, stderr, status = Open3.capture3(
        { "PROVIDER_RESULT_PATH" => result_path },
        RbConfig.ruby,
        "-I#{lib_path}",
        fixture_path,
      )
      expect(status).to be_success, "#{stdout}\n#{stderr}"

      result = JSON.parse(File.read(result_path))
      expect(result.fetch("same_provider")).to be(true)
      expect(result.fetch("customer_continued")).to be(true)
      expect(result.fetch("buildkite_stopped")).to be(true)
      expect(result.fetch("buildkite_shutdown_calls")).to eq(1)
      expect(result.dig("buildkite_resource", "service.name")).to eq("customer-service")
      expect(result.dig("buildkite_resource", "buildkite.test.run.id")).to eq("run-123")
      expect(result.dig("customer_resource", "service.name")).to eq("customer-service")
      expect(result.fetch("customer_resource")).not_to have_key("buildkite.test.run.id")
    end
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
    Buildkite::TestCollector::OTel.finish_test_span(
      failed_span,
      result: "failed",
      tags: { "component" => "checkout" },
    )
    skipped_span = span_class.new({})
    Buildkite::TestCollector::OTel.finish_test_span(
      skipped_span,
      result: "skipped",
    )

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
    Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, true)
    Buildkite::TestCollector::OTel.instance_variable_set(:@processor, processor)

    expect { Buildkite::TestCollector::OTel.force_flush }.not_to raise_error
    expect { Buildkite::TestCollector::OTel.shutdown }.not_to raise_error
    expect(Buildkite::TestCollector::OTel).not_to be_enabled
  ensure
    Buildkite::TestCollector::OTel.instance_variable_set(:@enabled, false)
    Buildkite::TestCollector::OTel.instance_variable_set(:@processor, nil)
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

  it "uses tag names for Buildkite tag refs and omits Codeship pull request URLs" do
    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_BUILD_ID", "build-id")
    fake_env("BUILDKITE_TAG", "v3.0.0")
    fake_env("BUILDKITE_ANALYTICS_URL", nil)
    fake_env("GITHUB_RUN_ID", nil)
    fake_env("CIRCLE_WORKFLOW_ID", nil)
    fake_env("CI_NAME", nil)

    tag_attributes = Buildkite::TestCollector::OTel.send(
      :resource_attributes,
      { "branch" => "main" }
    )
    expect(tag_attributes).to include(
      "vcs.ref.head.name" => "v3.0.0",
      "vcs.ref.type" => "tag",
    )

    fake_env("BUILDKITE_BUILD_ID", nil)
    codeship_attributes = Buildkite::TestCollector::OTel.send(
      :resource_attributes,
      {
        "CI" => "codeship",
        "url" => "https://github.com/acme/repo/pull/123",
      }
    )
    expect(codeship_attributes).not_to have_key("cicd.pipeline.run.url.full")
  end
end
