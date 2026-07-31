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

        Buildkite::TestCollector.configure(hook: :rspec, tracing_enabled: false)

        external_id = "019c8d97-f9ad-75a5-8173-dc6c1b54b901"
        SecureRandom.define_singleton_method(:uuid_v7) { external_id }

        exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
        provider = OpenTelemetry::SDK::Trace::TracerProvider.new
        provider.add_span_processor(processor)
        $otel_tracer = provider.tracer("correlation-test")
        Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, $otel_tracer)

        at_exit do
          provider.force_flush
          result = {
            uploads: $uploads,
            spans: exporter.finished_spans.map do |span|
              {
                name: span.name,
                span_id: span.span_id.unpack1("H*"),
                parent_span_id: span.parent_span_id.unpack1("H*"),
                trace_id: span.trace_id.unpack1("H*"),
                attributes: span.attributes,
              }
            end,
          }
          provider.shutdown
          File.write(ENV.fetch("CORRELATION_RESULT_PATH"), JSON.generate(result))
        end

        Buildkite::TestCollector::Uploader.define_singleton_method(:upload) do |traces|
          $uploads = traces.map(&:as_hash)
          nil
        end

        RSpec.describe "instrumented example" do
          it "makes an auto-instrumented span" do
            Buildkite::TestCollector.tag_execution("component", "checkout")
            $otel_tracer.in_span("http.request") { nil }
            $otel_tracer.in_span("sql.query") { nil }
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
      expect(result.fetch("uploads").length).to eq(1)
      expect(result.dig("uploads", 0, "external_id")).to eq("019c8d97-f9ad-75a5-8173-dc6c1b54b901")

      expect(result.fetch("spans").length).to eq(3)
      execution_span = result.fetch("spans").find { |span| span.fetch("name") == "test.execution" }
      child_spans = result.fetch("spans") - [execution_span]
      expect(execution_span.fetch("name")).to eq("test.execution")
      expect(execution_span.dig("attributes", "execution.externalId")).to eq("019c8d97-f9ad-75a5-8173-dc6c1b54b901")
      expect(execution_span.dig("attributes", "test.case.result.status")).to eq("pass")
      expect(execution_span.dig("attributes", "buildkite.test.execution.tag.component")).to eq("checkout")

      expect(child_spans.map { |span| span.fetch("name") }).to contain_exactly("http.request", "sql.query")
      child_spans.each do |child_span|
        expect(child_span.fetch("parent_span_id")).to eq(execution_span.fetch("span_id"))
        expect(child_span.fetch("trace_id")).to eq(execution_span.fetch("trace_id"))
        expect(child_span.fetch("attributes")).not_to have_key("execution.externalId")
        expect(child_span.fetch("attributes")).not_to have_key("buildkite.test.execution.tag.component")
      end
    end
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
        Buildkite::TestCollector::OTel.instance_variable_set(
          :@tracer,
          provider.tracer("final-result-test"),
        )
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
          instance_variable_set(:@tracer, nil)
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
          "process.command" => "/private/customer/bin/rspec",
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
        OpenTelemetry.tracer_provider.force_flush

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
      expect(result.dig("buildkite_resource", "buildkite.test.run.key")).to eq("run-123")
      expect(result.dig("buildkite_resource", "process.command")).to eq("rspec")
      expect(result.dig("customer_resource", "service.name")).to eq("customer-service")
      expect(result.dig("customer_resource", "process.command")).to eq("/private/customer/bin/rspec")
      expect(result.fetch("customer_resource")).not_to have_key("buildkite.test.run.key")
    end
  end

  it "keeps Buildkite resource attributes exporter-local when initializing the SDK" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "proxy-provider.json")
      fixture_path = File.join(directory, "proxy_provider.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"
        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"

        buildkite_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        OpenTelemetry::Exporter::OTLP::Exporter.define_singleton_method(:new) do |**_options|
          buildkite_exporter
        end

        Buildkite::TestCollector::OTel.configure!(
          endpoint: "https://example.invalid/v1/traces",
          run_env: { "key" => "run-123" },
        )

        provider = OpenTelemetry.tracer_provider
        customer_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        customer_processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
          customer_exporter,
        )
        provider.add_span_processor(customer_processor)

        tracer = provider.tracer("customer")
        tracer.in_span("proxy-provider-span") { nil }
        provider.force_flush

        buildkite_span = buildkite_exporter.finished_spans.find do |span|
          span.name == "proxy-provider-span"
        end
        customer_span = customer_exporter.finished_spans.find do |span|
          span.name == "proxy-provider-span"
        end

        Buildkite::TestCollector::OTel.shutdown
        provider.shutdown

        File.write(
          ENV.fetch("PROXY_PROVIDER_RESULT_PATH"),
          JSON.generate(
            buildkite_resource: buildkite_span.resource.attribute_enumerator.to_h,
            customer_resource: customer_span.resource.attribute_enumerator.to_h,
          ),
        )
      RUBY

      stdout, stderr, status = Open3.capture3(
        { "PROXY_PROVIDER_RESULT_PATH" => result_path },
        RbConfig.ruby,
        "-I#{lib_path}",
        fixture_path,
      )
      expect(status).to be_success, "#{stdout}\n#{stderr}"

      result = JSON.parse(File.read(result_path))
      expect(result.dig("buildkite_resource", "buildkite.test.run.key")).to eq("run-123")
      expect(result.fetch("customer_resource")).not_to have_key("buildkite.test.run.key")
    end
  end

end
