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
      @establish_subscription_queue = Queue.new
      @channel = channel

      @unconfirmed_idents = {}
      @idents_mutex = Mutex.new
      @empty = ConditionVariable.new
      @closing = false
      @reconnection_mutex = Mutex.new

      @url = url
      @authorization_header = authorization_header

      @logger = Logger.new

      connect
    rescue TimeoutError, InitialConnectionFailure => e
      $stderr.puts "rspec-buildkite-analytics could not establish an initial connection with Buildkite due to #{e.message}. You may be missing some data for this test suite, please contact support."
    end

    def disconnected(connection)
      reconnection_count = 0
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

        begin
          reconnection_count += 1
          connect
        rescue SocketConnection::HandshakeError, RejectedSubscription, TimeoutError, SocketConnection::SocketError => e
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

      @idents_mutex.synchronize do
        @logger.write("waiting for last confirm")
        # Here, we sleep for 75 seconds while waiting for the server to confirm the last idents.
        # We are woken up when the unconfirmed_idents is empty, and given back the mutex to
        # continue operation.
        @empty.wait(@idents_mutex, CONFIRMATION_TIMEOUT) unless @unconfirmed_idents.empty?
      end

      # Then we always disconnect cos we can't wait forever? 🤷‍♀️
      @connection.close
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
      result_as_json = result.as_json

      add_unconfirmed_idents(result.id, result_as_json)

      transmit_results([result_as_json])

      @logger.write("transmitted #{result.id}")
    end

    def unconfirmed_idents_count
      @idents_mutex.synchronize do
        @unconfirmed_idents.count
      end
    end

    private

    def transmit_results(results_as_json)
      @connection.transmit({
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "record_results",
          "results" => results_as_json
          }.to_json
        })
    end

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

      @logger.write("connected")
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

        @logger.write("received confirm for indentifiers: #{idents.join(", ")}")

        # This @empty ConditionVariable broadcasts every time that @unconfirmed_idents is
        # empty, which will happen about every 10mb of data as that's when the server
        # sends back confirmations.
        #
        # However, there aren't any threads waiting on this signal until after we
        # send the EOT message, so the prior broadcasts shouldn't do anything.
        @empty.broadcast if @unconfirmed_idents.empty?
      end
    end

    def send_eot
      # Expect server to respond with data of indentifiers last upload part

      @connection.transmit({
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "end_of_transmission",
          "examples_count" => @examples_count.to_json
        }.to_json
      })

      @logger.write("transmitted EOT")
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

    def retransmit
      data = @idents_mutex.synchronize do
        @unconfirmed_idents.values
      end

      # send the contents of the buffer, unless it's empty
      unless data.empty?
        @logger.write("retransmitting data")
        transmit_results(data)
      end

      # if we were disconnected in the closing phase, then resend the EOT
      # message so the server can persist the last upload part
      send_eot if @closing
    end
  end
end
