# frozen_string_literal: true

require_relative "socket_connection"

module RSpec::Buildkite::Analytics
  class Session
    # Picked 75 as the magic timeout number as it's longer than the TCP timeout of 60s 🤷‍♀️
    CONFIRMATION_TIMEOUT = 75
    MAX_RECONNECTION_ATTEMPTS = 3
    WAIT_BETWEEN_RECONNECTIONS = 5

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
      @channel = channel

      @unconfirmed_idents = {}
      @idents_mutex = Mutex.new
      @closing = false
      @outgoing_messages = Queue.new

      @url = url
      @authorization_header = authorization_header

      @logger = Logger.new
      @thread = Thread.new do
        start_network_loop_with_retries
      end

      # TODO this should be a proper "wait until connection established"
      sleep 5
    end

    def close(examples_count)
      @closing = true
      @examples_count = examples_count
      @logger.write("closing socket connection")

      @logger.write("waiting for last confirm")

      # Wait for the server to confirm the last idents, or for the network thread to have stopped
      # If the network thread has stopped then it presumably had trouble sending the data and we'll
      # never get confirmations
      loop_until = Time.now + CONFIRMATION_TIMEOUT
      loop do
        break if Time.now > loop_until

        break if unconfirmed_idents_count == 0

        # thread exited with an exception (status nil) or exited normally (status false)
        break if @thread.status.nil? || @thread.status == false

        sleep 1
      end

      if unconfirmed_idents_count == 0
        @logger.write("close: all results confirmed")
      else
        # Give up waiting for the server to confirm the idents and just close the connection
        @logger.write "close: returning with some data unconfirmed"
        @logger.write "close: unconfirmed_idents: #{unconfirmed_idents_ids}"
      end

      # The network thread stop normally once there's no work left to send
      @thread.join
    end

    def write_result(result)
      result_as_json = result.as_json
      add_unconfirmed_idents(result.id, result_as_json)

      @outgoing_messages << {
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "record_results",
          "results" => [result_as_json]
        }.to_json
      }
      @logger.write("transmitted #{result.id}")
    end

    def unconfirmed_idents_count
      @idents_mutex.synchronize do
        @unconfirmed_idents.count
      end
    end

    private

    def unconfirmed_idents_ids
      @idents_mutex.synchronize do
        @unconfirmed_idents.keys
      end
    end

    def start_network_loop_with_retries
      reconnection_count = 0
      begin
        reconnection_count += 1
        # TODO replace this call with a thing that re-queues all the unconfirmed messages. We're inside the network thread here
        # but we don't have an established SocketConnection so we can't retransmit them immediately, the queue will have to do
        retransmit_unconfirmed_data
        start_network_loop
        # TODO maybe we want to catch more errors here, like the openssl negative arg one, EPIPE, ECONNRESET, etc
      rescue SocketConnection::HandshakeError, RejectedSubscription, TimeoutError, SocketConnection::SocketError, ArgumentError => e
        # For networking errors, assume they might be transient and retry a few times
        @logger.write "start_network_loop_with_retries: exception"
        @logger.write "start_network_loop_with_retries: #{e.inspect}"
        Array(e.backtrace).each do |line|
          @logger.write "start_network_loop_with_retries: #{line}"
        end
        if reconnection_count > MAX_RECONNECTION_ATTEMPTS
          @logger.write "start_network_loop_with_retries: exceeded #{MAX_RECONNECTION_ATTEMPTS} attempts, giving up"
          $stderr.puts "rspec-buildkite-analytics experienced a disconnection and could not reconnect to Buildkite due to #{e.message}. Please contact support."
          raise e
        else
          sleep(WAIT_BETWEEN_RECONNECTIONS)
          retry
        end
      rescue StandardError => e
        # All non-network errors, let the thread crash once we've recorded the details for debugging
        @logger.write "start_network_loop_with_retries: exception"
        @logger.write "start_network_loop_with_retries: #{e.inspect}"
        Array(e.backtrace).each do |line|
          @logger.write "start_network_loop_with_retries: #{line}"
        end
      end
    end

    def start_network_loop
      @logger.write("start_network_loop: starting socket connection process")

      connection = SocketConnection.new(@url, {
        "Authorization" => @authorization_header,
      })

      @logger.write "start_network_loop: waiting for welcome"

      wait_for_welcome(connection)

      @logger.write "start_network_loop: got welcome"

      connection.transmit({
        "command" => "subscribe",
        "identifier" => @channel
      })

      @logger.write "start_network_loop: waiting for confirm"

      wait_for_confirm(connection)

      @logger.write("start_network_loop: got confirm")

      loop do
        @logger.write "start_network_loop: about to check for incoming"

        # check for incoming messages, confirm idents as required
        if msg = connection.next_message
          @logger.write "start_network_loop: incoming message - #{msg}"
          handle(nil, msg)
        end

        @logger.write "start_network_loop: about to transmit"

        # transmit anything in the queue
        while @outgoing_messages.size > 0
          msg = @outgoing_messages.pop
          @logger.write "start_network_loop: outgoing message - #{msg}"
          connection.transmit(msg)
        end

        if @closing
          # Because the server only sends us confirmations after every 10mb of
          # data it uploads to S3, we'll never get confirmation of the
          # identifiers of the last upload part unless we send an explicit finish,
          # to which the server will respond with the last bits of data
          send_eot(connection)
        end

        if @closing && unconfirmed_idents_count == 0
          # we're shutting down and there's no unconfirmed results, so we can
          # break the endless loop and allow the network thread to end
          @logger.write "start_network_loop: no remaining work, exiting"
          break
        end
      end
    end

    def next_with_timeout(connection, message_type)
      Timeout.timeout(30, RSpec::Buildkite::Analytics::TimeoutError, "Timeout: Waited 30 seconds for #{message_type}") do
        loop do
          msg = connection.next_message
          @logger.write "next_with_timeout: message - #{msg}"
          # skip pings
          if msg && msg["type"] == message_type
            return msg
          end
        end
      end
    end

    def wait_for_welcome(connection)
      welcome = next_with_timeout(connection, "welcome")

      if welcome && welcome != { "type" => "welcome" }
        raise InitialConnectionFailure.new("Wrong message received, expected a welcome, but received: #{welcome.inspect}")
      end
    end

    def wait_for_confirm(connection)
      confirm = next_with_timeout(connection, "confirm_subscription")

      if confirm && confirm != { "type" => "confirm_subscription", "identifier" => @channel }
        raise InitialConnectionFailure.new("Wrong message received, expected a confirm, but received: #{confirm.inspect}")
      end
    end

    def add_unconfirmed_idents(ident, data)
      @idents_mutex.synchronize do
        @unconfirmed_idents[ident] = data
      end
    end

    def remove_unconfirmed_idents(idents)
      return if idents.empty?

      @idents_mutex.synchronize do
        # Remove received idents from unconfirmed_idents
        idents.each { |key| @unconfirmed_idents.delete(key) }

        @logger.write("received confirm for identifiers: #{idents.join(", ")}")
      end
    end

    def send_eot(connection)
      # Expect server to respond with data of indentifiers last upload part
      connection.transmit({
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "end_of_transmission",
          "examples_count" => @examples_count.to_json
        }.to_json
      })

      @logger.write("transmitted EOT")
    end

    def handle(_connection, data)
      case data["type"]
      when "ping"
        # In absence of other message, the server sends us a ping every 3 seconds
        # We are currently not doing anything with these
      when "welcome", "confirm_subscription"
        # These are handled explictly by the network loop, so we don't expect to get them in normal
        # operation
      when "reject_subscription"
        raise RejectedSubscription
      else
        process_message(data)
      end
    end

    def process_message(data)
      # Check we're getting the data we expect
      return unless data["identifier"] == @channel

      case
      when data["message"].key?("confirm")
        remove_unconfirmed_idents(data["message"]["confirm"])
      else
        # unhandled message
        @logger.write("received unhandled message #{data["message"]}")
      end
    end

    def retransmit_unconfirmed_data
      @idents_mutex.synchronize do
        return if @unconfirmed_idents.empty?

        @logger.write("retransmit_unconfirmed_data: about to retransmit unconfirmed results")

        @unconfirmed_idents.each do |id, data|
          @outgoing_messages << {
            "identifier" => @channel,
            "command" => "message",
            "data" => {
              "action" => "record_results",
              "results" => [data]
            }.to_json
          }
          @logger.write("retransmit_unconfirmed_data: queued #{id}")
        end
      end
    end
  end
end
