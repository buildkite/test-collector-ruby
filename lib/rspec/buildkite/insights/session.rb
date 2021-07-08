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

      wait_for_welcome

      @socket.transmit({ "command" => "subscribe", "identifier" => @channel })

      wait_for_confirm
    end

    def connected(socket)
    end

    def disconnected(_socket)
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
  end
end
