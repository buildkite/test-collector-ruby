# frozen_string_literal: true

require "opentelemetry/sdk"
require "timeout"

forwarder_class = Buildkite::TestCollector::OTel.const_get(:ExecutionChildForwarder, false)

RSpec.describe forwarder_class do
  subject(:forwarder) { described_class.new(processor, context_key: context_key) }

  let(:success) { OpenTelemetry::SDK::Trace::Export::SUCCESS }
  let(:processor) do
    spy("execution child processor", on_finish: nil, force_flush: success, shutdown: success)
  end
  let(:context_key) { OpenTelemetry::Context.create_key("execution") }
  let(:execution_trace_id) { "\1" * 16 }
  let(:execution_context) { OpenTelemetry::Context.empty.set_value(context_key, execution_trace_id) }
  let(:span) { double("span", context: double("span context", trace_id: execution_trace_id)) }

  it "forwards only spans from the execution trace" do
    unrelated_span = double("unrelated span")
    detached_span = double(
      "detached span",
      context: double("detached span context", trace_id: "\2" * 16),
    )

    forwarder.on_start(unrelated_span, OpenTelemetry::Context.empty)
    forwarder.on_finish(unrelated_span)
    forwarder.on_start(detached_span, execution_context)
    forwarder.on_finish(detached_span)
    forwarder.on_start(span, execution_context)
    forwarder.on_finish(span)

    expect(processor).to have_received(:on_finish).with(span).once
    expect(processor).not_to have_received(:on_finish).with(unrelated_span)
    expect(processor).not_to have_received(:on_finish).with(detached_span)
  end

  it "remembers an accepted span until it finishes" do
    forwarder.on_start(span, execution_context)

    forwarder.on_finish(span)
    forwarder.on_finish(span)

    expect(processor).to have_received(:on_finish).with(span).once
  end

  it "becomes inert without shutting down the child processor" do
    forwarder.on_start(span, execution_context)

    expect(forwarder.force_flush(timeout: 5)).to eq(success)
    expect(forwarder.shutdown).to eq(success)
    forwarder.on_finish(span)

    expect(processor).to have_received(:force_flush).with(timeout: 5).once
    expect(processor).not_to have_received(:shutdown)
    expect(processor).not_to have_received(:on_finish)
  end

  it "does not block span completion or deactivation during a flush" do
    flush_started = Queue.new
    release_flush = Queue.new
    flush_thread = nil
    allow(processor).to receive(:force_flush) do
      flush_started << true
      release_flush.pop
      success
    end
    forwarder.on_start(span, execution_context)

    flush_thread = Thread.new { forwarder.force_flush }
    flush_started.pop
    Timeout.timeout(1) do
      forwarder.on_finish(span)
      forwarder.shutdown
    end
    release_flush << true

    expect(flush_thread.value).to eq(success)
    expect(processor).to have_received(:on_finish).with(span).once
  ensure
    release_flush&.push(true) if flush_thread&.alive?
    flush_thread&.join
  end

  it "does not expose child processor failures to the suite" do
    allow(processor).to receive(:on_finish).and_raise("queue failed")
    allow(processor).to receive(:force_flush).and_raise("flush failed")
    forwarder.on_start(span, execution_context)

    expect { forwarder.on_finish(span) }
      .to output(/Could not export OpenTelemetry child span: RuntimeError: queue failed/).to_stderr
    expect { expect(forwarder.force_flush).to eq(OpenTelemetry::SDK::Trace::Export::FAILURE) }
      .to output(/Could not flush OpenTelemetry child spans: RuntimeError: flush failed/).to_stderr
  end

  it "keeps the root when the child queue overflows" do
    root_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    child_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new
    root_processor = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      root_exporter,
      max_queue_size: 4,
      max_export_batch_size: 4,
      start_thread_on_boot: false,
    )
    child_processor = OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      child_exporter,
      max_queue_size: 4,
      max_export_batch_size: 4,
      start_thread_on_boot: false,
    )
    root_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    root_provider.add_span_processor(root_processor)
    suite_provider = OpenTelemetry::SDK::Trace::TracerProvider.new
    suite_provider.add_span_processor(
      described_class.new(child_processor, context_key: context_key)
    )
    root_tracer = root_provider.tracer("root")
    suite_tracer = suite_provider.tracer("suite")

    root = root_tracer.start_span("test.execution")
    OpenTelemetry::Context.with_value(context_key, root.context.trace_id) do
      OpenTelemetry::Trace.with_span(root) do
        10.times { |index| suite_tracer.in_span("child-#{index}") { nil } }
      end
    end
    root.finish
    root_processor.force_flush
    child_processor.force_flush

    expect(root_exporter.finished_spans.map(&:name)).to contain_exactly("test.execution")
    expect(child_exporter.finished_spans.size).to eq(4)
  ensure
    suite_provider&.shutdown
    root_provider&.shutdown
    child_processor&.shutdown
  end
end
