# frozen_string_literal: true

module Buildkite
  module TestCollector
    module OTel
      # OpenTelemetry cannot remove installed processors, so shutdown makes this inert.
      class RootPreservingSpanProcessor
        def initialize(root:, children:)
          @root = root
          @children = children
          @active = true
        end

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

        # Roots get the shared timeout first; shutdown still attempts both workers.
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
