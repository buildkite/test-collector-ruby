# frozen_string_literal: true

module RSpec::Buildkite::Insights
  class TimedoutQueue
    def initialize(timeout = 30)
      @timeout = timeout
      @queue = Queue.new
      @mutex = Mutex.new
    end

    def push(obj)
      @queue.push(obj)
    end

    def pop
      to_finish_at = now + @timeout

      @mutex.synchronize do
        loop do
          if (to_finish_at - now) <= 0
            raise RSpec::Buildkite::Insights::TimeoutError, "Waited #{@timeout} seconds"
          else
            return @queue.pop
          end
        end
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
