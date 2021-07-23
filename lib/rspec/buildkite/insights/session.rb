# frozen_string_literal: true

require_relative "socket_connection"

module RSpec::Buildkite::Insights
  class Session
    # Picked 75 as the magic timeout number as it's longer than the TCP timeout of 60s 🤷‍♀️
    CONFIRMATION_TIMEOUT = 75
    MAX_RECONNECTION_ATTEMPTS = 3
    WAIT_BETWEEN_RECONNECTIONS = 5

    class RejectedSubscription < StandardError; end

    def initialize(url, authorization_header, channel)
      @queue = Queue.new
      @channel = channel

      @unconfirmed_idents = {}
      @idents_mutex = Mutex.new
      @empty = ConditionVariable.new
      @closing = false
      @reconnection_mutex = Mutex.new

      @url = url
      @authorization_header = authorization_header

      connect
    end

    def disconnected(socket)
      reconnection_count = 0
      @reconnection_mutex.synchronize do
        return unless socket == @socket
        begin
          reconnection_count += 1
          connect
        rescue SocketConnection::HandshakeError, RejectedSubscription, TimeoutError, SocketConnection::SocketError => e
          if reconnection_count > MAX_RECONNECTION_ATTEMPTS
            raise e
          else
            sleep(WAIT_BETWEEN_RECONNECTIONS)
            retry
          end
        end
      end
      retransmit
    end

    def close()
      @closing = true

      # Because the server only sends us confirmations after every 10mb of
      # data it uploads to S3, we'll never get confirmation of the
      # identifiers of the last upload part unless we send an explicit finish,
      # to which the server will respond with the last bits of data
      send_eot

      @idents_mutex.synchronize do
        # Here, we sleep for 75 seconds while waiting for the server to confirm the last idents.
        # We are woken up when the unconfirmed_idents is empty, and given back the mutex to
        # continue operation.
        @empty.wait(@idents_mutex, CONFIRMATION_TIMEOUT) unless @unconfirmed_idents.empty?
      end

      # Then we always disconnect cos we can't wait forever? 🤷‍♀️
      @socket.close
    end

    def handle(_socket, data)
      data = JSON.parse(data)
      case data["type"]
      when "ping"
        # In absence of other message, the server sends us a ping every 3 seconds
        # We are currently not doing anything with these
      when "welcome", "confirm_subscription"
        # Push these two messages onto the queue, so that we block on waiting for the
        # initializing phase to complete
        @queue.push(data)
      when "reject_subscription"
        raise RejectedSubscription
      else
        process_message(data)
      end
    end

    def write_result(result)
      result_as_json = result.as_json

      add_unconfirmed_idents(result.example.id, result_as_json)

      transmit_results([result_as_json])
    end

    def unconfirmed_idents_count
      @idents_mutex.synchronize do
        @unconfirmed_idents.count
      end
    end

    private

    def transmit_results(results_as_json)
      @socket.transmit({
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "record_results",
          "results" => results_as_json
          }.to_json
        })
    end

    def connect
      @socket = SocketConnection.new(self, @url, {
        "Authorization" => @authorization_header,
      })

      wait_for_welcome

      @socket.transmit({
        "command" => "subscribe",
        "identifier" => @channel
      })

      wait_for_confirm
    end

    def pop_with_timeout
      Timeout.timeout(30, RSpec::Buildkite::Insights::TimeoutError, "Waited 30 seconds") do
        @queue.pop
      end
    end

    def wait_for_welcome
      welcome = pop_with_timeout

      if welcome && welcome != { "type" => "welcome" }
        raise "Not a welcome: #{welcome.inspect}"
      end
    end

    def wait_for_confirm
      confirm = pop_with_timeout

      if confirm && confirm != { "type" => "confirm_subscription", "identifier" => @channel }
        raise "Not a confirm: #{confirm.inspect}"
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

      @socket.transmit({
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      })
    end

    def process_message(data)
      # Check we're getting the data we expect
      return unless data["identifier"] == @channel

      case
      when data["message"].key?("confirm")
        remove_unconfirmed_idents(data["message"]["confirm"])
      else
        # unhandled message
      end
    end

    def retransmit
      data = @idents_mutex.synchronize do
        @unconfirmed_idents.values
      end

      transmit_results(data) unless data.empty?
      send_eot if @closing
    end
  end
end
