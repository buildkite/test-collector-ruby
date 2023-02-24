# frozen_string_literal: true

module Buildkite::TestCollector
  class Uploader
    MAX_UPLOAD_ATTEMPTS = 3

    def self.traces
      @traces ||= {}
    end

    REQUEST_EXCEPTIONS = [
      URI::InvalidURIError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      Net::ReadTimeout,
      Net::OpenTimeout,
      OpenSSL::SSL::SSLError,
      OpenSSL::SSL::SSLErrorWaitReadable,
      EOFError
    ]

    RETRYABLE_UPLOAD_ERRORS = [
      Net::ReadTimeout,
      Net::OpenTimeout,
      OpenSSL::SSL::SSLError,
      OpenSSL::SSL::SSLErrorWaitReadable,
      EOFError
    ]

    def self.configure
      Buildkite::TestCollector.logger.debug("hello from main thread")

      if Buildkite::TestCollector.api_token
        http = Buildkite::TestCollector::HTTPClient.new(Buildkite::TestCollector.url)

        response = begin
          http.post
        rescue *Buildkite::TestCollector::Uploader::REQUEST_EXCEPTIONS => e
          Buildkite::TestCollector.logger.error "Buildkite Test Analytics: Error communicating with the server: #{e.message}"
        end

        return unless response

        case response.code
        when "401"
          Buildkite::TestCollector.logger.info "Buildkite Test Analytics: Invalid Suite API key. Please double check your Suite API key."
        when "200"
          json = JSON.parse(response.body)

          if (socket_url = json["cable"]) && (channel = json["channel"])
            Buildkite::TestCollector.session = Buildkite::TestCollector::SocketSession.new(socket_url, http.authorization_header, channel)
          end
        else
          request_id = response.to_hash["x-request-id"]
          Buildkite::TestCollector.logger.info "buildkite-test_collector could not establish an initial connection with Buildkite. You may be missing some data for this test suite, please contact support with request ID #{request_id}."
        end
      else
        if !!ENV["BUILDKITE_BUILD_ID"]
          Buildkite::TestCollector.logger.info "Buildkite Test Analytics: No Suite API key provided. You can get the API key from your Suite settings page."
        end
      end
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end

    def self.upload(data)
      return false unless Buildkite::TestCollector.api_token

      http = Buildkite::TestCollector::HTTPClient.new(Buildkite::TestCollector.url)

      Thread.new do
        response = begin
          upload_attempts ||= 0
          http.post_json(data)
        rescue *Buildkite::TestCollector::Uploader::RETRYABLE_UPLOAD_ERRORS => e
          if (upload_attempts += 1) < MAX_UPLOAD_ATTEMPTS
            retry
          end
        end
      end
    end
  end
end
