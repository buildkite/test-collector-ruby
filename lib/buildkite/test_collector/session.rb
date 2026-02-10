# frozen_string_literal: true

require "concurrent-ruby"

module Buildkite::TestCollector
  class Session
    UPLOAD_SESSION_TIMEOUT = 60
    UPLOAD_API_MAX_RESULTS = 5000

    def initialize
      @send_queue_ids = []
      @upload_futures = []
    end

    def add_example_to_send_queue(id)
      @send_queue_ids << id

      if @send_queue_ids.size >= Buildkite::TestCollector.batch_size
        send_ids = @send_queue_ids.shift(Buildkite::TestCollector.batch_size)
        upload_data(send_ids)
      end
    end

    def send_remaining_data
      return if @send_queue_ids.empty?

      upload_data(@send_queue_ids)
      @send_queue_ids.clear
    end

    def close
      return if @upload_futures.empty?

      begin
        Concurrent::Promises.zip(*@upload_futures).value!(UPLOAD_SESSION_TIMEOUT)
      rescue StandardError
        # Timeout or other error - futures will continue running in the thread pool
        # with their own per-upload timeouts, we just stop waiting for them
      ensure
        @upload_futures.clear
      end
    end

    private

    def upload_data(ids)
      data = Buildkite::TestCollector.uploader.traces.values_at(*ids).compact

      begin
        # We do this in batches of UPLOAD_API_MAX_RESULTS in case the number of
        # results exceeds this due to a bug, or user error in configuring the
        # batch size
        data.each_slice(UPLOAD_API_MAX_RESULTS) do |batch|
          new_future = Buildkite::TestCollector::Uploader.upload(batch)
          @upload_futures << new_future if new_future
        end
      ensure
        # Free memory by removing uploaded traces from the in-memory cache
        ids.each { |id| Buildkite::TestCollector.uploader.traces.delete(id) }
      end
    end
  end
end
