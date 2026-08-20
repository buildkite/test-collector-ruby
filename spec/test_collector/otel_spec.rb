# frozen_string_literal: true

require "open3"
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/trace/propagation/trace_context"

RSpec.describe Buildkite::TestCollector::OTel do
  it "starts the execution as a root and links it to the Agent job trace" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    tracer = provider.tracer("correlation-test")
    job_trace_id = "0af7651916cd43dd8448eb211c80319c"
    job_span_id = "b7ad6b7169203331"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TRACEPARENT")
      .and_return("00-#{job_trace_id}-#{job_span_id}-01")
    allow(ENV).to receive(:[]).with("TRACESTATE").and_return("vendor=value")

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
    expect(execution_span.links.length).to eq(1)
    expect(execution_span.links.first.span_context.hex_trace_id).to eq(job_trace_id)
    expect(execution_span.links.first.span_context.hex_span_id).to eq(job_span_id)
    expect(execution_span.links.first.span_context.tracestate.to_s).to eq("vendor=value")
    expect(child_span.parent_span_id).to eq(execution_span.span_id)
    expect(child_span.trace_id).to eq(execution_span.trace_id)
    expect(ambient_span.trace_id).not_to eq(execution_span.trace_id)
  ensure
    described_class.instance_variable_set(:@tracer, nil)
    provider&.shutdown
  end

  it "skips missing or malformed Agent trace context" do
    exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    processor = OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(exporter)
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(processor)
    described_class.instance_variable_set(:@tracer, provider.tracer("invalid-link-test"))
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("TRACEPARENT").and_return(nil, "not-a-traceparent")
    allow(ENV).to receive(:[]).with("TRACESTATE").and_return(nil)

    2.times do
      span, = described_class.start_test_span
      described_class.finish_test_span(span)
    end
    provider.force_flush

    expect(exporter.finished_spans.map(&:links)).to all(be_empty)
    expect(exporter.finished_spans.map(&:parent_span_id))
      .to all(eq(OpenTelemetry::Trace::INVALID_SPAN_ID))
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
    test = double("test")

    expect { described_class.finish_test_span(nil, test: test) }.not_to raise_error
  end

  it "deactivates children, then shuts down roots and children against one deadline" do
    success = OpenTelemetry::SDK::Trace::Export::SUCCESS
    forwarder = double("execution child forwarder")
    execution_provider = double("execution provider")
    child_processor = double("execution child processor")
    described_class.instance_variable_set(:@execution_child_forwarder, forwarder)
    described_class.instance_variable_set(:@execution_provider, execution_provider)
    described_class.instance_variable_set(:@execution_child_processor, child_processor)
    allow(Process).to receive(:clock_gettime)
      .with(Process::CLOCK_MONOTONIC)
      .and_return(10.0, 12.0, 13.0)

    expect(forwarder).to receive(:shutdown).ordered.and_return(success)
    expect(execution_provider).to receive(:shutdown).with(timeout: 28.0).ordered.and_return(success)
    expect(child_processor).to receive(:shutdown).with(timeout: 27.0).ordered.and_return(success)

    described_class.shutdown
  end

  it "attempts child shutdown when root shutdown fails" do
    execution_provider = double("execution provider")
    child_processor = spy(
      "execution child processor",
      shutdown: OpenTelemetry::SDK::Trace::Export::SUCCESS,
    )
    allow(execution_provider).to receive(:shutdown).and_raise("root shutdown failed")
    described_class.instance_variable_set(:@execution_provider, execution_provider)
    described_class.instance_variable_set(:@execution_child_processor, child_processor)

    expect { described_class.shutdown }
      .to output(/Could not shut down OpenTelemetry span export: RuntimeError: root shutdown failed/)
      .to_stderr
    expect(child_processor).to have_received(:shutdown).with(timeout: be_between(0, 30))
    expect(described_class).not_to be_enabled
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

  it "shuts down the execution processor when private provider setup fails" do
    execution_processor = spy(
      "OpenTelemetry execution processor",
      shutdown: OpenTelemetry::SDK::Trace::Export::SUCCESS,
    )
    allow(described_class).to receive(:batch_processor).and_return(execution_processor)
    allow(OpenTelemetry::SDK::Trace::TracerProvider)
      .to receive(:new)
      .and_raise(ArgumentError, "invalid private provider configuration")

    expect do
      described_class.configure!(endpoint: "https://example.invalid/v1/traces")
    end.to output(/OpenTelemetry span export disabled: ArgumentError/).to_stderr
    expect(execution_processor).to have_received(:shutdown).with(timeout: 0)
    expect(described_class).not_to be_enabled
  end

  it "keeps root export enabled when child processor setup fails" do
    suite_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(suite_provider)
    root_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    calls = 0
    allow(described_class).to receive(:batch_processor) do |_endpoint, _headers, options = {}|
      calls += 1
      raise ArgumentError, "invalid child queue configuration" if calls == 2

      OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(root_exporter, **options)
    end

    expect do
      described_class.configure!(endpoint: "https://example.invalid/v1/traces")
    end.to output(
      /OpenTelemetry child span export disabled: ArgumentError: invalid child queue configuration; test.execution export remains enabled/
    ).to_stderr

    execution_span, = described_class.start_test_span
    described_class.finish_test_span(execution_span)
    described_class.instance_variable_get(:@execution_provider).force_flush

    expect(described_class).to be_enabled
    expect(root_exporter.finished_spans.map(&:name)).to contain_exactly("test.execution")
  ensure
    described_class.shutdown
    suite_provider&.shutdown
  end

  it "makes a partially attached child forwarder inert and stops its worker" do
    success = OpenTelemetry::SDK::Trace::Export::SUCCESS
    execution_processor = spy(
      "execution processor",
      on_start: nil,
      on_finish: nil,
      shutdown: success,
    )
    child_processor = spy(
      "execution child processor",
      on_finish: nil,
      shutdown: success,
    )
    suite_provider = double("suite provider")
    forwarder = nil
    allow(suite_provider).to receive(:add_span_processor) do |attached|
      forwarder = attached
      raise "attachment failed"
    end
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(suite_provider)
    allow(described_class).to receive(:batch_processor)
      .and_return(execution_processor, child_processor)

    expect do
      described_class.configure!(endpoint: "https://example.invalid/v1/traces")
    end.to output(
      /OpenTelemetry child span export disabled: RuntimeError: attachment failed; test.execution export remains enabled/
    ).to_stderr

    trace_id = "\1" * 16
    context = OpenTelemetry::Context.empty.set_value(
      described_class.send(:execution_context_key),
      trace_id,
    )
    span = double("suite span", context: double("span context", trace_id: trace_id))
    forwarder.on_start(span, context)
    forwarder.on_finish(span)

    expect(described_class).to be_enabled
    expect(child_processor).to have_received(:shutdown).with(timeout: 0).once
    expect(child_processor).not_to have_received(:on_finish)

    described_class.shutdown
    expect(execution_processor).to have_received(:shutdown).once
    expect(child_processor).to have_received(:shutdown).once
  ensure
    described_class.shutdown
  end

  it "cleans up a child worker when collector provider setup partially fails" do
    success = OpenTelemetry::SDK::Trace::Export::SUCCESS
    execution_processor = spy(
      "execution processor",
      on_start: nil,
      on_finish: nil,
      shutdown: success,
    )
    child_processor = spy(
      "execution child processor",
      on_finish: nil,
      shutdown: success,
    )
    proxy_provider = OpenTelemetry::Internal::ProxyTracerProvider.new
    config = double("OpenTelemetry SDK configuration")
    forwarder = nil
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(proxy_provider)
    allow(config).to receive(:id_generator=)
    allow(config).to receive(:add_span_processor) { |attached| forwarder = attached }
    allow(OpenTelemetry::SDK).to receive(:configure) do |&block|
      block.call(config)
      raise "provider setup failed"
    end
    allow(described_class).to receive(:batch_processor)
      .and_return(execution_processor, child_processor)

    expect do
      described_class.configure!(
        endpoint: "https://example.invalid/v1/traces",
        instrumentations: [],
      )
    end.to output(
      /OpenTelemetry child span export disabled: RuntimeError: provider setup failed; test.execution export remains enabled/
    ).to_stderr

    trace_id = "\1" * 16
    context = OpenTelemetry::Context.empty.set_value(
      described_class.send(:execution_context_key),
      trace_id,
    )
    span = double("collector span", context: double("span context", trace_id: trace_id))
    forwarder.on_start(span, context)
    forwarder.on_finish(span)

    expect(described_class).to be_enabled
    expect(child_processor).to have_received(:shutdown).with(timeout: 0).once
    expect(child_processor).not_to have_received(:on_finish)

    described_class.shutdown
    expect(execution_processor).to have_received(:shutdown).once
    expect(child_processor).to have_received(:shutdown).once
  ensure
    described_class.shutdown
  end

  it "uses process-safe IDs and installs registered instrumentation for collector-managed children" do
    child_processor = spy(
      "execution child processor",
      shutdown: OpenTelemetry::SDK::Trace::Export::SUCCESS,
    )
    provider = OpenTelemetry::Internal::ProxyTracerProvider.new
    config = double("OpenTelemetry SDK configuration")
    generator = described_class.const_get(:SecureRandomIdGenerator, false)
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
    allow(OpenTelemetry::SDK).to receive(:configure).and_yield(config)
    allow(config).to receive(:add_span_processor)
    allow(config).to receive(:id_generator=)
    allow(config).to receive(:use_all)
    allow(described_class).to receive(:batch_processor).and_return(child_processor)

    described_class.send(
      :attach_execution_children,
      "https://example.invalid/v1/traces",
      {},
      nil,
    )

    expect(config).to have_received(:id_generator=).with(generator)
    expect(config).to have_received(:add_span_processor)
      .with(an_instance_of(described_class.const_get(:ExecutionChildForwarder, false)))
    expect(config).to have_received(:use_all).once
  ensure
    described_class.shutdown
  end

  it "does not install registered instrumentation with an empty selection" do
    provider = OpenTelemetry::Internal::ProxyTracerProvider.new
    config = double("OpenTelemetry SDK configuration")
    child_processor = spy(
      "execution child processor",
      shutdown: OpenTelemetry::SDK::Trace::Export::SUCCESS,
    )
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
    allow(OpenTelemetry::SDK).to receive(:configure).and_yield(config)
    allow(config).to receive(:id_generator=)
    allow(config).to receive(:add_span_processor)
    allow(config).to receive(:use_all)
    allow(described_class).to receive(:batch_processor).and_return(child_processor)

    described_class.send(
      :attach_execution_children,
      "https://example.invalid/v1/traces",
      {},
      [],
    )

    expect(config).not_to have_received(:use_all)
  ensure
    described_class.shutdown
  end

  it "fails open for instrumentation selections reserved for a later release" do
    expect do
      described_class.configure!(instrumentations: [:all])
    end.to output(
      /OpenTelemetry span export disabled: ArgumentError: otel_instrumentations must be omitted or \[\]/
    ).to_stderr

    expect(described_class).not_to be_enabled
  end

  it "sends the run key and token as request headers" do
    headers = described_class.send(:request_headers, { "key" => "test-run-id" }, "suite-token")

    expect(headers).to eq(
      "Buildkite-Tests-Run-Key" => "test-run-id",
      "Authorization" => %(Token token="suite-token"),
    )
  end

  it "uses an AlwaysOn sampler and process-safe random IDs for execution roots" do
    processor = spy(
      "execution processor",
      shutdown: OpenTelemetry::SDK::Trace::Export::SUCCESS,
    )
    generator = described_class.const_get(:SecureRandomIdGenerator, false)
    allow(described_class).to receive(:batch_processor).and_return(processor)

    execution_provider = described_class.send(
      :build_execution_provider,
      "https://example.invalid/v1/traces",
      {},
    )

    expect(execution_provider.id_generator).to equal(generator)
    expect(execution_provider.sampler).to equal(OpenTelemetry::SDK::Trace::Samplers::ALWAYS_ON)
  ensure
    execution_provider&.shutdown
  end

  it "exports roots privately and only forwards execution children" do
    suite_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    allow(suite_exporter).to receive(:shutdown).and_call_original
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    provider.add_span_processor(
      OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(suite_exporter)
    )
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)

    root_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    child_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    allow(root_exporter).to receive(:shutdown)
      .and_return(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    allow(child_exporter).to receive(:shutdown)
      .and_return(OpenTelemetry::SDK::Trace::Export::SUCCESS)
    allow(OpenTelemetry::Exporter::OTLP::Exporter)
      .to receive(:new)
      .and_return(root_exporter, child_exporter)
    root_reporter = described_class.const_get(:RootSpanMetricsReporter, false)
    expect(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor)
      .to receive(:new)
      .with(
        root_exporter,
        max_queue_size: described_class::ROOT_MAX_QUEUE_SIZE,
        max_export_batch_size: described_class::ROOT_MAX_EXPORT_BATCH_SIZE,
        schedule_delay: described_class::ROOT_SCHEDULE_DELAY_MILLISECONDS,
        metrics_reporter: an_instance_of(root_reporter),
      )
      .ordered
      .and_call_original
    expect(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor)
      .to receive(:new)
      .with(child_exporter)
      .ordered
      .and_call_original
    described_class.configure!(endpoint: "https://example.invalid/v1/traces")

    tracer = provider.tracer("suite")
    tracer.in_span("before-execution") { nil }
    execution_span, = described_class.start_test_span
    late_child = nil
    described_class.with_test_span(execution_span) do
      tracer.in_span("child") { nil }
      detached = tracer.start_span("detached", with_parent: OpenTelemetry::Context.empty)
      OpenTelemetry::Trace.with_span(detached) do
        tracer.in_span("detached-child") { nil }
      end
      detached.finish
      late_child = tracer.start_span("late-child")
    end
    described_class.finish_test_span(execution_span)
    late_child.finish
    tracer.in_span("after-execution") { nil }
    described_class.instance_variable_get(:@execution_provider).force_flush
    described_class.instance_variable_get(:@execution_child_processor).force_flush
    provider.force_flush

    expect(OpenTelemetry.tracer_provider).to equal(provider)
    expect(execution_span.context.trace_flags).to be_sampled
    expect(root_exporter.finished_spans.map(&:name)).to contain_exactly("test.execution")
    expect(child_exporter.finished_spans.map(&:name)).to contain_exactly("child", "late-child")
    expect(suite_exporter.finished_spans.map(&:name))
      .to contain_exactly(
        "before-execution",
        "child",
        "detached",
        "detached-child",
        "late-child",
        "after-execution",
      )
    exported_root = root_exporter.finished_spans.fetch(0)
    exported_child = child_exporter.finished_spans.find { |span| span.name == "child" }
    expect(exported_child.trace_id).to eq(exported_root.trace_id)
    expect(exported_child.parent_span_id).to eq(exported_root.span_id)

    described_class.shutdown
    tracer.in_span("after-shutdown") { nil }
    provider.force_flush

    expect(child_exporter.finished_spans.map(&:name)).not_to include("after-shutdown")
    expect(suite_exporter.finished_spans.map(&:name)).to include("after-shutdown")
    expect(suite_exporter).not_to have_received(:shutdown)
  ensure
    described_class.shutdown
    provider&.shutdown
  end

  it "leaves instrumentation alone when the suite owns its provider" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
    allow(OpenTelemetry::SDK).to receive(:configure)
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new) do
      OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    end

    expect do
      described_class.configure!(
        endpoint: "https://example.invalid/v1/traces",
        instrumentations: [],
      )
    end.to output(
      /instrumentation selection ignored because the test suite already configured OpenTelemetry: \[\]/
    ).to_stderr

    expect(described_class).to be_enabled
    expect(OpenTelemetry::SDK).not_to have_received(:configure)
  ensure
    described_class.shutdown
    provider&.shutdown
  end

  it "exports roots when the suite's sampler drops child spans" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new(
      sampler: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF,
    )
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
    root_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    child_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    allow(OpenTelemetry::Exporter::OTLP::Exporter)
      .to receive(:new)
      .and_return(root_exporter, child_exporter)
    described_class.configure!(endpoint: "https://example.invalid/v1/traces")

    execution_span, = described_class.start_test_span
    described_class.with_test_span(execution_span) do
      provider.tracer("suite").in_span("sampled-out-child") { nil }
    end
    described_class.finish_test_span(execution_span)
    described_class.instance_variable_get(:@execution_provider).force_flush
    described_class.instance_variable_get(:@execution_child_processor).force_flush

    expect(execution_span.context.trace_flags).to be_sampled
    expect(root_exporter.finished_spans.map(&:name)).to contain_exactly("test.execution")
    expect(child_exporter.finished_spans).to be_empty
  ensure
    described_class.shutdown
    provider&.shutdown
  end

  it "keeps private root export alive if the suite shuts down its provider" do
    provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
    root_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    child_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    allow(OpenTelemetry::Exporter::OTLP::Exporter)
      .to receive(:new)
      .and_return(root_exporter, child_exporter)
    described_class.configure!(endpoint: "https://example.invalid/v1/traces")

    provider.shutdown
    provider = nil
    execution_span, = described_class.start_test_span
    described_class.finish_test_span(execution_span)
    described_class.instance_variable_get(:@execution_provider).force_flush

    expect(root_exporter.finished_spans.map(&:name)).to contain_exactly("test.execution")
  ensure
    described_class.shutdown
    provider&.shutdown
  end

  it "configures collector-managed children without suite OpenTelemetry" do
    script = <<~'RUBY'
      require "buildkite/test_collector"
      require "opentelemetry/sdk"
      require "opentelemetry/exporter/otlp"

      original_provider = OpenTelemetry.tracer_provider
      exporters = []
      OpenTelemetry::Exporter::OTLP::Exporter.singleton_class.define_method(:new) do |**_options|
        exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
        exporters << exporter
        exporter
      end

      Buildkite::TestCollector::OTel.configure!(
        endpoint: "https://example.invalid/v1/traces",
        instrumentations: [],
      )
      span, = Buildkite::TestCollector::OTel.start_test_span
      Buildkite::TestCollector::OTel.with_test_span(span) do
        OpenTelemetry.tracer_provider.tracer("application").in_span("child") { nil }
      end
      Buildkite::TestCollector::OTel.finish_test_span(span)
      Buildkite::TestCollector::OTel.instance_variable_get(:@execution_provider).force_flush
      Buildkite::TestCollector::OTel.instance_variable_get(:@execution_child_processor).force_flush

      puts "global-provider-configured=#{!OpenTelemetry.tracer_provider.equal?(original_provider)}"
      puts "exporters=#{exporters.length}"
      puts exporters.flat_map { |exporter| exporter.finished_spans.map(&:name) }
      Buildkite::TestCollector::OTel.shutdown
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.lines.map(&:chomp)).to include(
      "global-provider-configured=true",
      "exporters=2",
      "test.execution",
      "child",
    )
  end

  it "keeps root export enabled with an incompatible suite provider" do
    root_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(Object.new)
    allow(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new).and_return(root_exporter)

    expect do
      described_class.configure!(endpoint: "https://example.invalid/v1/traces")
    end.to output(
      /OpenTelemetry child span export disabled: RuntimeError: existing OpenTelemetry tracer provider does not support adding a span processor; test.execution export remains enabled/
    ).to_stderr

    execution_span, = described_class.start_test_span
    described_class.finish_test_span(execution_span)
    described_class.instance_variable_get(:@execution_provider).force_flush

    expect(described_class).to be_enabled
    expect(root_exporter.finished_spans.map(&:name)).to contain_exactly("test.execution")
  ensure
    described_class.shutdown
  end
end
