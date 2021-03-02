# frozen_string_literal: true

module RSpec::Buildkite::Insights
  class Instrumentations
    class Network
      module NetHTTPPatch
        def request(request, *args, &block)
          # No request.uri for localhost requests
          url = request.uri.nil? ? request.path : request.uri

          RSpec::Buildkite::Insights::Uploader.trace(:http, method: request.method, url: url, lib: "net-http") do
            super
          end
        end
      end

      module VCRPatch
        def handle
          RSpec::Buildkite::Insights::Uploader.trace(:http, method: request.method, url: request.uri.to_s, lib: "vcr") do
            super
          end
        end
      end

      module HTTPPatch
        def perform(request, options)
          RSpec::Buildkite::Insights::Uploader.trace(:http, method: request.verb.to_s, url: request.uri.to_s, lib: "http") do
            super
          end
        end
      end

      def self.configure
        if defined?(VCR)
          require "vcr/request_handler"
          VCR::RequestHandler.prepend(VCRPatch)
        end

        if defined?(Net) && defined?(Net::HTTP)
          Net::HTTP.prepend(NetHTTPPatch)
        end

        if defined?(HTTP) && defined?(HTTP::Client)
          HTTP::Client.prepend(HTTPPatch)
        end
      end
    end
  end
end
