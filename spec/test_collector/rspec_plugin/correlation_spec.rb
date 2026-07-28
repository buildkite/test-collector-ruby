# frozen_string_literal: true

require "open3"

RSpec.describe "RSpec execution and OpenTelemetry correlation" do
  it "uses one external ID for the upload and execution span without copying it to children" do
    Dir.mktmpdir do |directory|
      result_path = File.join(directory, "correlation.json")
      fixture_path = File.join(directory, "correlation_spec.rb")
      lib_path = File.expand_path("../../../lib", __dir__)

      File.write(fixture_path, <<~RUBY)
        require "json"
        require "buildkite/test_collector"

        class RecordingOTelTracer
          Span = Struct.new(:name, :span_id, :parent_span_id, :trace_id, :attributes)

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
        Buildkite::TestCollector::UUID.define_singleton_method(:call) do
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

        Buildkite::TestCollector::Uploader.define_singleton_method(:upload) do |traces|
          result = {
            generated_external_ids: $generated_external_ids,
            uploads: traces.map(&:as_hash),
            spans: $recording_otel_tracer.spans.map do |span|
              {
                name: span.name,
                span_id: span.span_id,
                parent_span_id: span.parent_span_id,
                trace_id: span.trace_id,
                attributes: span.attributes,
              }
            end,
          }
          File.write(ENV.fetch("CORRELATION_RESULT_PATH"), JSON.generate(result))
          nil
        end

        RSpec.describe "instrumented example" do
          it "makes an auto-instrumented span" do
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

      expect(child_span.fetch("name")).to eq("http.request")
      expect(child_span.fetch("parent_span_id")).to eq(execution_span.fetch("span_id"))
      expect(child_span.fetch("trace_id")).to eq(execution_span.fetch("trace_id"))
      expect(child_span.fetch("attributes")).not_to have_key("execution.externalId")
    end
  end
end
