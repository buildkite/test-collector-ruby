# frozen_string_literal: true

module Buildkite
  module TestCollector
    module OTel
      # Root spans are the required input for an OTLP-only test execution, while
      # automatic instrumentation can produce thousands of less important child
      # spans. Give each kind its own batch processor so child queue pressure and
      # child export failures cannot evict or reject test.execution spans.
      #
      # Once a processor is added to an OpenTelemetry provider it cannot be
      # removed. This processor therefore becomes inert after shutdown rather
      # than leaving its queues active with no workers to empty them.
      class RootPreservingSpanProcessor
        def initialize(root:, children:)
          @root = root
          @children = children
          @active = true
        end

        # BatchSpanProcessor has no work to do until a span finishes.
        def on_start(_span, _parent_context); end

        def on_finish(span)
          processor_for(span).on_finish(span) if @active
        end

        def force_flush(timeout: nil)
          return success unless @active

          finish_processors(:force_flush, timeout)
        end

        def shutdown(timeout: nil)
          return success unless @active

          @active = false
          finish_processors(:shutdown, timeout)
        end

        private

        def processor_for(span)
          span.name == ROOT_SPAN_NAME ? @root : @children
        end

        # Give roots first use of the caller's timeout, then use the remainder for
        # other spans. Always invoke both processors so an exporter failure cannot
        # leave the other processor's worker running.
        def finish_processors(method, timeout)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout if timeout
          result = success
          error = nil

          [@root, @children].each do |processor|
            remaining = [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max if deadline
            begin
              processor_result = processor.public_send(method, timeout: remaining)
              result = [result, processor_result].max
            rescue StandardError => e
              error ||= e
            end
          end

          raise error if error

          result
        end

        def success
          OpenTelemetry::SDK::Trace::Export::SUCCESS
        end
      end
      private_constant :RootPreservingSpanProcessor
    end
  end
end
