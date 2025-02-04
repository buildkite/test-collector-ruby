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
      EOFError,
      Errno::ETIMEDOUT,
      # TODO: some retries for server-side error would be great.
    ]

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end

    def self.upload(data)
      return false unless Buildkite::TestCollector.api_token

      http = Buildkite::TestCollector::HTTPClient.new(
        url: Buildkite::TestCollector.url,
        api_token: Buildkite::TestCollector.api_token,
      )

      Thread.new do
        begin
          upload_attempts ||= 0
          http.post_upload(
            data: data,
            run_env: Buildkite::TestCollector::CI.env,
          )

        rescue *Buildkite::TestCollector::Uploader::RETRYABLE_UPLOAD_ERRORS => e
          retry if (upload_attempts += 1) < MAX_UPLOAD_ATTEMPTS

        rescue StandardError => e
          $stderr.puts e
          $stderr.puts "#{Buildkite::TestCollector::NAME} #{Buildkite::TestCollector::VERSION} experienced an error when sending your data, you may be missing some executions for this run."
        end
      end
    end
  end
end
