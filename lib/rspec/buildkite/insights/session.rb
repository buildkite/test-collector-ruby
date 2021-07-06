# frozen_string_literal: true

require_relative "socket_connection"

module RSpec::Buildkite::Insights
  class Session
    def initialize(url, authorization_header, channel)
      @queue = Queue.new
      @channel = channel

      @socket = SocketConnection.new(self, url, {
        "Authorization" => authorization_header,
      })

      verify_welcome(@queue.pop)

      if connected?
        @socket.transmit({ "command" => "subscribe", "identifier" => @channel })
        verify_confirm(@queue.pop)
      end
    end

    def connected?
      @socket_connected == true
    end

    def connected(_socket)
      @socket_connected = true
    end

    def disconnected(_socket)
      @socket_connected = false
    end

    def handle(_socket, data)
      data = JSON.parse(data)
      if data["type"] == "ping"
        # FIXME: If we don't pong, I'm pretty sure we'll get
        # disconnected
      else
        @queue.push(data)
      end
    end

    def write_result(result)
      @socket.transmit({ "identifier" => @channel, "command" => "message", "data" => { "action" => "record_results", "results" => [result.as_json] }.to_json})
    end

    private

    def verify_welcome(welcome)
      unless welcome == { "type" => "welcome" }
        raise "Not a welcome: #{welcome.inspect}"
      end
    end

    def verify_confirm(confirm)
      unless confirm == { "type" => "confirm_subscription", "identifier" => @channel }
        raise "Not a confirm: #{confirm.inspect}"
      end
    end
  end
end
