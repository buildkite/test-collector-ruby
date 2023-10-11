# frozen_string_literal: true

module Buildkite::TestCollector
  class Session
    UPLOAD_THREAD_TIMEOUT = 60
    UPLOAD_SESSION_TIMEOUT = 60
    UPLOAD_API_MAX_RESULTS = 5000

    def initialize
      @send_queue_ids = []
      @upload_threads = []
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
    end

    def close
      # There are two thread joins here, because the inner join will wait up to
      # UPLOAD_THREAD_TIMEOUT seconds PER thread that is uploading data, i.e.
      # n_threads x UPLOAD_THREAD_TIMEOUT latency if Buildkite happens to be
      # down. By wrapping that in an outer thread join with the
      # UPLOAD_SESSION_TIMEOUT, we ensure that we only wait a max of
      # UPLOAD_SESSION_TIMEOUT seconds before the session exits.
      Thread.new do
        @upload_threads.each { |t| t.join(UPLOAD_THREAD_TIMEOUT) }
      end.join(UPLOAD_SESSION_TIMEOUT)

      @upload_threads.each { |t| t&.kill }
    end

    def upload_response
      Buildkite::TestCollector.uploader.traces.values_at(*@send_queue_ids).compact
    end

    private

    def upload_data(ids)
      data = Buildkite::TestCollector.uploader.traces.values_at(*ids).compact

      # we do this in batches of UPLOAD_API_MAX_RESULTS in case the number of
      # results exceeds this due to a bug, or user error in configuring the
      # batch size
      data.each_slice(UPLOAD_API_MAX_RESULTS) do |batch|
        new_thread = Buildkite::TestCollector::Uploader.upload(batch)
        @upload_threads << new_thread if new_thread
      end
    end
  end
end
