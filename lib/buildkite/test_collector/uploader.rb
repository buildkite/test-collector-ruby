# frozen_string_literal: true

require "concurrent-ruby"

module Buildkite::TestCollector
  class Uploader
    MAX_UPLOAD_ATTEMPTS = 3
    UPLOAD_TIMEOUT = 60

    THREAD_POOL_SIZE = 10
    THREAD_POOL = Concurrent::FixedThreadPool.new(THREAD_POOL_SIZE)

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

    def self.traces
      @traces ||= {}
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end

    def self.upload(data)
      return unless Buildkite::TestCollector.api_token

      http = Buildkite::TestCollector::HTTPClient.new(
        url: Buildkite::TestCollector.url,
        api_token: Buildkite::TestCollector.api_token,
      )

      upload_future = Concurrent::Promises.future_on(THREAD_POOL) do
        begin
          upload_attempts ||= 0
          http.post_upload(
            data: data,
            run_env: Buildkite::TestCollector::CI.env,
            tags: Buildkite::TestCollector.tags,
          )

        rescue *Buildkite::TestCollector::Uploader::RETRYABLE_UPLOAD_ERRORS => e
          retry if (upload_attempts += 1) < MAX_UPLOAD_ATTEMPTS

        rescue StandardError => e
          $stderr.puts e
          $stderr.puts "#{Buildkite::TestCollector::NAME} #{Buildkite::TestCollector::VERSION} experienced an error when sending your data, you may be missing some executions for this run."
        end
      end

      timeout_future = Concurrent::Promises.schedule(UPLOAD_TIMEOUT) { :timeout }

      Concurrent::Promises.any(upload_future, timeout_future)
    end
  end
end
