# frozen_string_literal: true

require_relative "socket_connection"

module RSpec::Buildkite::Insights
  class Session
    # Picked 75 as the magic timeout number as it's longer than the TCP timeout of 60s 🤷‍♀️
    CONFIRMATION_TIMEOUT = 75

    def initialize(url, authorization_header, channel)
      @queue = Queue.new
      @channel = channel

      # We store the unconfirmed_idents to check against confirmations sent by the server.
      # As this resource is accessed in the main thread, and also the socket listen thread,
      # we need a Mutex to protect access to this resource, and a ConditionVariable to
      # coordinate between threads.
      @unconfirmed_idents = {}
      @mutex = Mutex.new
      @empty = ConditionVariable.new

      @socket = SocketConnection.new(self, url, {
        "Authorization" => authorization_header,
      })

      wait_for_welcome

      @socket.transmit({
        "command" => "subscribe",
        "identifier" => @channel
      })

      wait_for_confirm
    end

    def connected(socket)
      # Some of the initialize code will probably be moved here once we implement reconnect
    end

    def disconnected(_socket)
      # Want to reconnect here if there are any unconfirmed_idents. We trust that the
      # server has thrown out whatever it had in flight and it expects the insight gem
      # to reconnect
    end

    def close()
      # Because the server only sends us confirmations after every 10mb of
      # data it uploads to S3, we'll never get confirmation of the
      # identifiers of the last upload part unless we send an explicit finish,
      # to which the server will respond with the last bits of data
      send_eot

      @mutex.synchronize do
        # Here, we sleep for 75 seconds while waiting for the server to confirm the last idents.
        # We are woken up when the unconfirmed_idents is empty, and given back the mutex to
        # continue operation.
        @empty.wait(@mutex, CONFIRMATION_TIMEOUT) unless @unconfirmed_idents.empty?
      end

      # 🤷‍♀️ I guess then we always disconnect cos we can't wait
      # forever? Perhaps when we implement reconnect, we'll do
      # one retry here, and then quit
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
      else
        process_message(data)
      end
    end

    def write_result(result)
      result_as_json = result.as_json

      @socket.transmit({
        "identifier" => @channel,
        "command" => "message",
        "data" => {
          "action" => "record_results",
          "results" => [result_as_json]
          }.to_json
        })

      add_unconfirmed_idents(result.example.id, result_as_json)
    end

    def unconfirmed_idents_count
      @mutex.synchronize do
        @unconfirmed_idents.count
      end
    end

    private

    def pop_with_timeout
      Timeout.timeout(30, RSpec::Buildkite::Insights::TimeoutError, "Waited 30 seconds") do
        @queue.pop
      end
    rescue RSpec::Buildkite::Insights::TimeoutError
      $stderr.puts "RSpec Buildkite Insights timed out. Please get in touch with support@buildkite.com with the following information: #{@channel.inspect}"
      nil
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
      @mutex.synchronize do
        @unconfirmed_idents[ident] = data
      end
    end

    def remove_unconfirmed_idents(idents)
      return if idents.empty?
      @mutex.synchronize do
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
  end
end
