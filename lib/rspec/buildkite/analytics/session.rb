# frozen_string_literal: true

require_relative "socket_connection"

module RSpec::Buildkite::Analytics
  class Session
    # Picked 75 as the magic timeout number as it's longer than the TCP timeout of 60s 🤷‍♀️
    CONFIRMATION_TIMEOUT = ENV.fetch("BUILDKITE_ANALYTICS_CONFIRMATION_TIMEOUT") { 75 }.to_i
    MAX_RECONNECTION_ATTEMPTS = ENV.fetch("BUILDKITE_ANALYTICS_RECONNECTION_ATTEMPTS") { 3 }.to_i
    WAIT_BETWEEN_RECONNECTIONS = ENV.fetch("BUILDKITE_ANALYTICS_RECONNECTION_WAIT") { 5 }.to_i
    UPLOAD_MESSAGES = ENV.fetch("BUILDKITE_ANALYTICS_UPLOAD_MESSAGES") { 1 }.to_i

    class RejectedSubscription < StandardError; end
    class InitialConnectionFailure < StandardError; end

    class Logger
      def initialize
        @log = Queue.new
      end

      def write(str)
        @log << "#{Time.now.strftime("%F-%R:%S.%9N")} #{Thread.current} #{str}"
      end

      def to_array
        # This empty check is important cos calling pop on a Queue is blocking until
        # it's not empty
        if @log.empty?
          []
        else
          Array.new(@log.size) { @log.pop }
        end
      end
    end

    attr_reader :logger

    def initialize(url, authorization_header, channel)
      @establish_subscription_queue = Queue.new
      @channel = channel

      @unconfirmed_idents = {}
      @idents_mutex = Mutex.new
      @send_queue = Queue.new
      @empty = ConditionVariable.new
      @closing = false
      @eot_queued = false
      @eot_queued_mutex = Mutex.new
      @reconnection_mutex = Mutex.new

      @url = url
      @authorization_header = authorization_header

      @logger = Logger.new

      reconnection_count = 0

      begin
        reconnection_count += 1
        connect
      rescue TimeoutError, InitialConnectionFailure => e
        @logger.write("rspec-buildkite-analytics could not establish an initial connection with Buildkite due to #{e}. Attempting retry #{reconnection_count} of #{MAX_RECONNECTION_ATTEMPTS}...")
        if reconnection_count > MAX_RECONNECTION_ATTEMPTS
          $stderr.puts "rspec-buildkite-analytics could not establish an initial connection with Buildkite due to #{e.message} after #{MAX_RECONNECTION_ATTEMPTS} attempts. You may be missing some data for this test suite, please contact support if this issue persists."
        else
          sleep(WAIT_BETWEEN_RECONNECTIONS)
          @logger.write("retrying reconnection")
          retry
        end
      end
      init_write_thread
    end

    def disconnected(connection)
      @reconnection_mutex.synchronize do
        # When the first thread detects a disconnection, it calls the disconnect method
        # with the current connection. This thread grabs the reconnection mutex and does the
        # reconnection, which then updates the value of @connection.
        #
        # At some point in that process, the second thread would have detected the
        # disconnection too, and it also calls it with the current connection. However, the
        # second thread can't run the reconnection code because of the mutex. By the
        # time the mutex is released, the value of @connection has been refreshed, and so
        # the second thread returns early and does not reattempt the reconnection.
        return unless connection == @connection
        @logger.write("starting reconnection")

        reconnection_count = 0

        begin
          reconnection_count += 1
          connect
          init_write_thread
        rescue SocketConnection::HandshakeError, RejectedSubscription, TimeoutError, InitialConnectionFailure, SocketConnection::SocketError => e
          @logger.write("failed reconnection attempt #{reconnection_count} due to #{e}")
          if reconnection_count > MAX_RECONNECTION_ATTEMPTS
            $stderr.puts "rspec-buildkite-analytics experienced a disconnection and could not reconnect to Buildkite due to #{e.message}. Please contact support."
            raise e
          else
            sleep(WAIT_BETWEEN_RECONNECTIONS)
            @logger.write("retrying reconnection")
            retry
          end
        end
      end
      retransmit
    end

    def close(examples_count)
      @closing = true
      @examples_count = examples_count
      @logger.write("closing socket connection")

      # Because the server only sends us confirmations after every 10mb of
      # data it uploads to S3, we'll never get confirmation of the
      # identifiers of the last upload part unless we send an explicit finish,
      # to which the server will respond with the last bits of data
      send_eot

      # After EOT, we wait for 75 seconds for the send queue to be drained and for the
      # server to confirm the last idents. If everything has already been confirmed we can
      # proceed without waiting.
      @idents_mutex.synchronize do
        if @unconfirmed_idents.any?
          if UPLOAD_MESSAGES == 1
            puts "Waiting for Buildkite Test Analytics to send results..."
          end
          @logger.write("waiting for last confirm")

          @empty.wait(@idents_mutex, CONFIRMATION_TIMEOUT)
        end
      end

      # Then we always disconnect cos we can't wait forever? 🤷‍♀️
      @connection.close
      # We kill the write thread cos it's got a while loop in it, so it won't finish otherwise
      @write_thread&.kill

      if UPLOAD_MESSAGES == 1
        puts "Buildkite Test Analytics completed"
      end
      @logger.write("socket connection closed")
    end

    def handle(_connection, data)
      data = JSON.parse(data)
      case data["type"]
      when "ping"
        # In absence of other message, the server sends us a ping every 3 seconds
        # We are currently not doing anything with these
        @logger.write("received ping")
      when "welcome", "confirm_subscription"
        # Push these two messages onto the queue, so that we block on waiting for the
        # initializing phase to complete
        @establish_subscription_queue.push(data)
      @logger.write("received #{data['type']}")
      when "reject_subscription"
        @logger.write("received rejected_subscription")
        raise RejectedSubscription
      else
        process_message(data)
      end
    end

    def write_result(result)
      queue_and_track_result(result.id, result.as_hash)

      @logger.write("added #{result.id} to send queue")
    end

    def unconfirmed_idents_count
      @idents_mutex.synchronize do
        @unconfirmed_idents.count
      end
    end

    private

    def connect
      @logger.write("starting socket connection process")

      @connection = SocketConnection.new(self, @url, {
        "Authorization" => @authorization_header,
      })

      wait_for_welcome

      @connection.transmit({
        "command" => "subscribe",
        "identifier" => @channel
      })

      wait_for_confirm

      if UPLOAD_MESSAGES == 1
        puts "Connected to Buildkite Test Analytics!"
      end
      @logger.write("connected")
    end

    def init_write_thread
      # As this method can be called multiple times in the
      # reconnection process, kill prev write threads (if any) before
      # setting up the new one
      @write_thread&.kill

      @write_thread = Thread.new do
        @logger.write("hello from write thread")
        # Pretty sure this eternal loop is fine cos the call to queue.pop is blocking
        loop do
          data = @send_queue.pop
          message_type = data["action"]

          if message_type == "end_of_transmission"
            # Because of the unpredictable sequencing between the test suite finishing
            # (EOT gets queued) and disconnections happening (retransmit results gets
            # queued), we don't want to send an EOT before any retransmits are sent.
            if @send_queue.length > 0
              @send_queue << data
              @logger.write("putting eot at back of queue")
              next
            end
            @eot_queued_mutex.synchronize do
              @eot_queued = false
            end
          end

          @connection.transmit({
            "identifier" => @channel,
            "command" => "message",
            "data" => data.to_json
          })

          if RSpec::Buildkite::Analytics.debug_enabled
            ids = if message_type == "record_results"
              data["results"].map { |result| result["id"] }
            end
            @logger.write("transmitted #{message_type} #{ids}")
          end
        end
      end
    end

    def pop_with_timeout(message_type)
      Timeout.timeout(30, RSpec::Buildkite::Analytics::TimeoutError, "Timeout: Waited 30 seconds for #{message_type}") do
        @establish_subscription_queue.pop
      end
    end

    def wait_for_welcome
      welcome = pop_with_timeout("welcome")

      if welcome && welcome != { "type" => "welcome" }
        raise InitialConnectionFailure.new("Wrong message received, expected a welcome, but received: #{welcome.inspect}")
      end
    end

    def wait_for_confirm
      confirm = pop_with_timeout("confirm")

      if confirm && confirm != { "type" => "confirm_subscription", "identifier" => @channel }
        raise InitialConnectionFailure.new("Wrong message received, expected a confirm, but received: #{confirm.inspect}")
      end
    end

    def queue_and_track_result(ident, result_as_hash)
      @idents_mutex.synchronize do
        @unconfirmed_idents[ident] = result_as_hash

        @send_queue << {
          "action" => "record_results",
          "results" => [result_as_hash]
        }
      end
    end

    def confirm_idents(idents)
      retransmit_required = @closing

      @idents_mutex.synchronize do
        # Remove received idents from unconfirmed_idents
        idents.each { |key| @unconfirmed_idents.delete(key) }

        @logger.write("received confirm for indentifiers: #{idents}")

        # This @empty ConditionVariable broadcasts every time that @unconfirmed_idents is
        # empty, which will happen about every 10mb of data as that's when the server
        # sends back confirmations.
        #
        # However, there aren't any threads waiting on this signal until after we
        # send the EOT message, so the prior broadcasts shouldn't do anything.
        if @unconfirmed_idents.empty?
          @empty.broadcast

          retransmit_required = false

          @logger.write("all identifiers have been confirmed")
        else
          @logger.write("still waiting on confirm for identifiers: #{@unconfirmed_idents.keys}")
        end
      end

      # If we're closing, any unconfirmed results need to be retransmitted.
      retransmit if retransmit_required
    end

    def send_eot
      @eot_queued_mutex.synchronize do
        return if @eot_queued

        @send_queue << {
          "action" => "end_of_transmission",
          "examples_count" => @examples_count.to_json
        }
        @eot_queued = true

        @logger.write("added EOT to send queue")
      end
    end

    def process_message(data)
      # Check we're getting the data we expect
      return unless data["identifier"] == @channel

      case
      when data["message"].key?("confirm")
        confirm_idents(data["message"]["confirm"])
      else
        # unhandled message
        @logger.write("received unhandled message #{data["message"]}")
      end
    end

    def retransmit
      @idents_mutex.synchronize do
        results = @unconfirmed_idents.values

        # queue the contents of the buffer, unless it's empty
        if results.any?
          @send_queue << {
            "action" => "record_results",
            "results" => results
          }

          @logger.write("queueing up retransmitted results #{@unconfirmed_idents.keys}")
        end
      end

      # if we were disconnected in the closing phase, then resend the EOT
      # message so the server can persist the last upload part
      send_eot if @closing
    end
  end
end
