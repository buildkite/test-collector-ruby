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
          begin
            return @queue.pop(true)
          rescue ThreadError
            # server not sending us data yet
          end

          if (to_finish_at - now) <= 0
            raise RSpec::Buildkite::Insights::TimeoutError, "Waited #{@timeout} seconds"
          end
        end
      end
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
