# frozen_string_literal: true

module RSpec::Buildkite::Insights
  class Network
    module NetHTTPPatch
      def request(request, *args, &block)
        unless uri = request.uri
          protocol = @use_ssl ? "https" : "http"
          uri = URI.join("#{protocol}://#{address}:#{port}", request.path)
        end

        detail = { method: request.method.upcase, url: uri.to_s, lib: "net-http" }

        http_tracer = RSpec::Buildkite::Insights::Uploader.tracer
        http_tracer&.enter("http", **detail)

        super
      ensure
        http_tracer&.leave
      end
    end

    module VCRPatch
      def handle
        if request_type == :stubbed_by_vcr && tracer = RSpec::Buildkite::Insights::Uploader.tracer
          tracer.current_span.detail.merge!(stubbed: "vcr")
        end

        super
      end
    end

    module HTTPPatch
      def perform(request, options)
        detail = { method: request.verb.to_s.upcase, url: request.uri.to_s, lib: "http" }

        http_tracer = RSpec::Buildkite::Insights::Uploader.tracer
        http_tracer&.enter("http", **detail)

        super
      ensure
        http_tracer&.leave
      end
    end

    module WebMockPatch
      def response_for_request(request_signature)
        response_from_webmock = super

        if response_from_webmock && tracer = RSpec::Buildkite::Insights::Uploader.tracer
          tracer.current_span.detail.merge!(stubbed: "webmock")
        end

        response_from_webmock
      end
    end
# concern visit, test call click_button <- Capybara has too many to patch
#
#  Patch it
#
#  #6  Selenium::WebDriver::Remote::Http::Default.request(verb#Symbol, url#URI::HTTP, headers#Hash, payload#String, redirects#Integer) at /Users/hhh/.rubies/ruby-2.7.2/lib/ruby/gems/2.7.0/gems/selenium-webdriver-3.142.3/lib/selenium/webdriver/remote/http/default.rb:82
    module CapybaraPatch
      def request
        http_tracer = RSpec::Buildkite::Insights::Uploader.tracer
        http_tracer&.disable

        super
      ensure
        http_tracer&.leave
      end
    end

    def self.configure
      if defined?(VCR)
        require "vcr/request_handler"
        VCR::RequestHandler.prepend(VCRPatch)
      end

      if defined?(Capybara)
        Capybara::Server::Checker.prepend(CapybaraPatch)
      end

      if defined?(WebMock)
        WebMock::StubRegistry.prepend(WebMockPatch)
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
