# frozen_string_literal: true

module Buildkite
  module TestCollector
    module OTel
      class ExecutionChildForwarder
        def initialize(processor, context_key:)
          @processor = processor
          @context_key = context_key
          @spans = {}
          @mutex = Mutex.new
          @active = true
        end

        def on_start(span, parent_context)
          execution_trace_id = parent_context.value(@context_key)
          return unless execution_trace_id
          return unless execution_trace_id == span.context.trace_id

          @mutex.synchronize do
            @spans[span] = true if @active
          end
        rescue StandardError => e
          warn "[buildkite-test_collector] Could not track OpenTelemetry child span: #{e.class}: #{e.message}"
        end

        def on_finish(span)
@mutex.synchronize do
  @processor.on_finish(span) if @active && @spans.delete(span)
end
        rescue StandardError => e
          warn "[buildkite-test_collector] Could not export OpenTelemetry child span: #{e.class}: #{e.message}"
        end

        def force_flush(timeout: nil)
          active = @mutex.synchronize { @active }
          return success unless active

          @processor.force_flush(timeout: timeout)
        rescue StandardError => e
          warn "[buildkite-test_collector] Could not flush OpenTelemetry child spans: #{e.class}: #{e.message}"
          OpenTelemetry::SDK::Trace::Export::FAILURE
        end

        def shutdown(timeout: nil)
          @mutex.synchronize do
            @active = false
            @spans.clear
          end
          success
        end

        private

        def success
          OpenTelemetry::SDK::Trace::Export::SUCCESS
        end
      end
      private_constant :ExecutionChildForwarder
    end
  end
end
