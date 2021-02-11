# frozen_string_literal: true

module RSpec::Buildkite::Insights::Instrumentation
  class NetHTTP
    def self.configure
      class Net::HTTP
        def request_with_bk_trace(request, *args, &block)
          start = Concurrent.monotonic_time
          response = request_without_bk_trace(request, *args, &block)
          finish = Concurrent.monotonic_time

          RSpec::Buildkite::Insights::Uploader.tracer&.backfill(:http, finish - start, { url: request.path })

          response
        end

        alias request_without_bk_trace request
        alias request request_with_bk_trace
      end
    end
  end
end
