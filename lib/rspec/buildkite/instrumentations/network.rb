# frozen_string_literal: true

module RSpec::Buildkite::Insights
  class Instrumentations
    class Network
      module NetHTTPPatch
        def request(request, *args, &block)
          response = nil

          start = Concurrent.monotonic_time
          response = super
          finish = Concurrent.monotonic_time

          RSpec::Buildkite::Insights::Uploader.tracer&.backfill(:http, finish - start, { method: request.method, path: request.path.to_s, url: request.uri.to_s })

          response
        end
      end

      module VCRPatch
        def handle
          response = nil

          start = Concurrent.monotonic_time
          response = super
          finish = Concurrent.monotonic_time

          RSpec::Buildkite::Insights::Uploader.tracer&.backfill(:http, finish - start, { method: request.method, url: request.uri.to_s })

          response
        end
      end

      module HTTPPatch
        def perform(request, options)
          response = nil

          start = Concurrent.monotonic_time
          response = super
          finish = Concurrent.monotonic_time

          RSpec::Buildkite::Insights::Uploader.tracer&.backfill(:http, finish - start, { method: request.verb.to_s, url: request.uri.to_s })

          response
        end
      end

      def self.configure
        case
        when defined?(VCR)
          require "vcr/request_handler"
          VCR::RequestHandler.prepend(VCRPatch)
        when defined?(Net) && defined?(Net::HTTP)
          Net::HTTP.prepend(NetHTTPPatch)
        when defined?(HTTP) && defined?(HTTP::Client)
          HTTP::Client.prepend(HTTPPatch)
        end
      end
    end
  end
end
