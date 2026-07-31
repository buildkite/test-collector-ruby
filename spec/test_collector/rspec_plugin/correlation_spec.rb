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
          TraceFlags = Struct.new(:sampled?)
          SpanContext = Struct.new(:trace_flags)

          Span = Struct.new(:name, :span_id, :parent_span_id, :trace_id, :attributes, :links, :status, :finished) do
            def context
              SpanContext.new(TraceFlags.new(true))
            end

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

          def start_span(name, with_parent: nil, attributes: {}, kind: nil, links: [])
            parent = OpenTelemetry::Trace.current_span(with_parent)
            parent = nil unless parent.respond_to?(:trace_id)
            span_id = format("%016x", @spans.length + 1)
            trace_id = parent ? parent.trace_id : format("%032x", @spans.length + 1)
            span = Span.new(name, span_id, parent ? parent.span_id : "", trace_id, attributes, links)
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
        Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, $recording_otel_tracer)

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
                links: span.links.map do |link|
                  {
                    trace_id: link.span_context.trace_id.unpack1("H*"),
                    span_id: link.span_context.span_id.unpack1("H*"),
                    trace_state: link.span_context.tracestate.to_s,
                  }
                end,
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
            $recording_otel_tracer.in_span("sql.query") { nil }
          end
        end
      RUBY

      rspec_path = Gem.bin_path("rspec-core", "rspec")
      agent_trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
      agent_span_id = "00f067aa0ba902b7"
      _stdout, stderr, status = Open3.capture3(
        {
          "CORRELATION_RESULT_PATH" => result_path,
          "TRACEPARENT" => "00-#{agent_trace_id}-#{agent_span_id}-01",
          "TRACESTATE" => "vendor=value,buildkite=agent",
        },
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

      expect(result.fetch("spans").length).to eq(3)
      execution_span, *child_spans = result.fetch("spans")
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
      expect(execution_span.fetch("parent_span_id")).to eq("")
      expect(execution_span.fetch("trace_id")).not_to eq(agent_trace_id)
      expect(execution_span.fetch("links")).to contain_exactly(
        {
          "trace_id" => agent_trace_id,
          "span_id" => agent_span_id,
          "trace_state" => "vendor=value,buildkite=agent",
        }
      )

      expect(child_spans.map { |span| span.fetch("name") }).to contain_exactly("http.request", "sql.query")
      child_spans.each do |child_span|
        expect(child_span.fetch("parent_span_id")).to eq(execution_span.fetch("span_id"))
        expect(child_span.fetch("trace_id")).to eq(execution_span.fetch("trace_id"))
        expect(child_span.fetch("attributes")).not_to have_key("execution.externalId")
        expect(child_span.fetch("attributes")).not_to have_key("buildkite.test.execution.tag.component")
      end
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
        Buildkite::TestCollector::OTel.instance_variable_set(:@tracer, raising_tracer)

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

  it "does not upload a dangling external ID when the execution span is not sampled" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "unsampled.json")
      fixture_path = File.join(directory, "unsampled_spec.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"
        require "opentelemetry/sdk"

        Buildkite::TestCollector.configure(hook: :rspec, tracing_enabled: false)

        provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
          sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF,
        )
        Buildkite::TestCollector::OTel.instance_variable_set(
          :@tracer,
          provider.tracer("unsampled-test"),
        )

        at_exit do
          provider.shutdown
          File.write(
            ENV.fetch("UNSAMPLED_RESULT_PATH"),
            JSON.generate(body_ran: $body_ran, uploads: $uploads),
          )
        end

        Buildkite::TestCollector::Uploader.define_singleton_method(:upload) do |traces|
          $uploads = traces.map(&:as_hash)
          nil
        end

        RSpec.describe "unsampled execution" do
          it "still runs" do
            $body_ran = true
          end
        end
      RUBY

      rspec_path = Gem.bin_path("rspec-core", "rspec")
      _stdout, stderr, status = Open3.capture3(
        { "UNSAMPLED_RESULT_PATH" => result_path },
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
        OpenTelemetry::Exporter::OTLP::Exporter.define_singleton_method(:new) do |**options|
          $buildkite_exporter_options = options
          buildkite_exporter
        end

        ENV["BUILDKITE_BUILD_ID"] = "build-id"
        ENV["BUILDKITE_JOB_ID"] = "019c8d97-f9ad-75a5-8173-dc6c1b54b901"

        Buildkite::TestCollector::OTel.configure!(
          endpoint: "https://example.invalid/v1/traces",
          run_env: {
            "CI" => "buildkite",
            "key" => "run-123",
            "job_id" => "019d8d97-f9ad-75a5-8173-dc6c1b54b902",
          },
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
            buildkite_exporter_headers: $buildkite_exporter_options.fetch(:headers),
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
      run_key_header = result.dig("buildkite_exporter_headers", "Buildkite-Test-Run-Key")
      run_key_resource = result.dig("buildkite_resource", "buildkite.test.run.key")
      expect(run_key_header).to eq("run-123")
      expect(run_key_resource).to eq(run_key_header)
      job_id_header = result.dig("buildkite_exporter_headers", "Buildkite-Test-Job-ID")
      expect(job_id_header).to eq("019c8d97-f9ad-75a5-8173-dc6c1b54b901")
      expect(result.dig("buildkite_resource", "buildkite.job.id")).to eq(job_id_header)
      expect(result.dig("buildkite_resource", "cicd.pipeline.task.run.id")).to eq(job_id_header)
      expect(result.fetch("buildkite_resource")).not_to have_key("buildkite.test.run.id")
      expect(result.dig("buildkite_resource", "process.command")).to eq("rspec")
      expect(result.dig("customer_resource", "service.name")).to eq("customer-service")
      expect(result.dig("customer_resource", "process.command")).to eq("/private/customer/bin/rspec")
      expect(result.fetch("customer_resource")).not_to have_key("buildkite.test.run.key")
      expect(result.fetch("customer_resource")).not_to have_key("buildkite.job.id")
      expect(result.fetch("customer_resource")).not_to have_key("cicd.pipeline.task.run.id")
      expect(result.fetch("customer_resource")).not_to have_key("buildkite.test.run.id")
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

  it "rejects invalid OpenTelemetry run identities without breaking the test or upload" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "invalid-run-keys.json")
      fixture_path = File.join(directory, "invalid_run_keys_spec.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"

        [nil, "run key", "rún-key", "run\nkey", "x" * 256].each do |run_key|
          run_env = run_key ? { "key" => run_key } : {}
          Buildkite::TestCollector::OTel.configure!(
            endpoint: "https://example.invalid/v1/traces",
            run_env: run_env,
          )
        end

        at_exit do
          File.write(
            ENV.fetch("INVALID_RUN_KEYS_RESULT_PATH"),
            JSON.generate(
              body_ran: $body_ran,
              uploads: $uploads,
              otel_enabled: Buildkite::TestCollector::OTel.enabled?,
            ),
          )
        end

        Buildkite::TestCollector::Uploader.define_singleton_method(:upload) do |traces|
          $uploads = traces.map(&:as_hash)
          nil
        end

        RSpec.describe "missing run identity" do
          it "still runs" do
            $body_ran = true
          end
        end
      RUBY

      rspec_path = Gem.bin_path("rspec-core", "rspec")
      _stdout, stderr, status = Open3.capture3(
        { "INVALID_RUN_KEYS_RESULT_PATH" => result_path },
        RbConfig.ruby,
        "-I#{lib_path}",
        rspec_path,
        fixture_path,
      )

      expect(status).to be_success, stderr
      expect(stderr.scan("a valid Buildkite test run key is required").length).to eq(5)
      result = JSON.parse(File.read(result_path))
      expect(result.fetch("body_ran")).to be(true)
      expect(result.fetch("uploads").length).to eq(1)
      expect(result.fetch("otel_enabled")).to be(false)
    end
  end

end
