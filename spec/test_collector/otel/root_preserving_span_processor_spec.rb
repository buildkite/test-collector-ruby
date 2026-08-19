# frozen_string_literal: true

require "opentelemetry/sdk"

processor_class = Buildkite::TestCollector::OTel.const_get(:RootPreservingSpanProcessor, false)

RSpec.describe processor_class do
  subject(:processor) { described_class.new(root: root_processor, children: children_processor) }

  let(:success) { OpenTelemetry::SDK::Trace::Export::SUCCESS }
  let(:failure) { OpenTelemetry::SDK::Trace::Export::FAILURE }
  let(:root_processor) do
    spy("root processor", force_flush: success, shutdown: success)
  end
  let(:children_processor) do
    spy("children processor", force_flush: success, shutdown: success)
  end
  let(:root_span) { double("root span", name: "test.execution") }
  let(:child_span) { double("child span", name: "http.request") }

  describe "#on_start" do
    it "does not wake either batch processor" do
      processor.on_start(root_span, OpenTelemetry::Context.empty)

      expect(root_processor).not_to have_received(:on_start)
      expect(children_processor).not_to have_received(:on_start)
    end
  end

  describe "#on_finish" do
    it "routes execution roots to the reserved processor" do
      processor.on_finish(root_span)

      expect(root_processor).to have_received(:on_finish).with(root_span)
      expect(children_processor).not_to have_received(:on_finish)
    end

    it "routes every other span to the children processor" do
      processor.on_finish(child_span)

      expect(children_processor).to have_received(:on_finish).with(child_span)
      expect(root_processor).not_to have_received(:on_finish)
    end
  end

  describe "#force_flush" do
    it "gives roots first use of one shared timeout" do
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(10.0, 12.0, 13.0)
      expect(root_processor).to receive(:force_flush).with(timeout: 8.0).ordered.and_return(success)
      expect(children_processor).to receive(:force_flush).with(timeout: 7.0).ordered.and_return(failure)

      expect(processor.force_flush(timeout: 10)).to eq(failure)
    end
  end

  describe "#shutdown" do
    it "shuts down both processors even when the root processor raises" do
      error = RuntimeError.new("root shutdown failed")
      allow(root_processor).to receive(:shutdown).and_raise(error)

      expect { processor.shutdown }.to raise_error(error)
      expect(children_processor).to have_received(:shutdown).with(timeout: nil)
    end

    it "becomes inert after the first shutdown" do
      expect(processor.shutdown).to eq(success)

      processor.on_finish(root_span)

      expect(processor.shutdown).to eq(success)
      expect(processor.force_flush).to eq(success)
      expect(root_processor).to have_received(:shutdown).once
      expect(children_processor).to have_received(:shutdown).once
      expect(root_processor).not_to have_received(:on_finish)
    end
  end
end
