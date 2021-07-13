# frozen_string_literal: true

require_relative "socket_connection"

module RSpec::Buildkite::Insights
  class Session
    def initialize(url, authorization_header, channel, timeout:)
      @queue = Queue.new
      @channel = channel
      @timeout = timeout

      @socket = SocketConnection.new(self, url, {
        "Authorization" => authorization_header,
      })

      return unless verify_welcome(pop_with_timeout)

      @socket.transmit({ "command" => "subscribe", "identifier" => @channel })

      verify_confirm(pop_with_timeout)
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

    attr_reader :timeout

    def pop_with_timeout
      timeout! { @queue.pop }
    rescue RSpec::Buildkite::Insights::TimeoutError
      $stderr.puts "RSpec Buildkite Insights timed out. Please get in touch with support@buildkite.com with the following information: #{@channel.inspect}"
      nil
    end

    def timeout!
      Timeout.timeout(timeout, RSpec::Buildkite::Insights::TimeoutError, "Waited #{timeout} seconds") do
        yield
      end
    end

    def verify_welcome(welcome)
      return unless welcome

      if welcome != { "type" => "welcome" }
        raise "Not a welcome: #{welcome.inspect}"
      else
        true
      end
    end

    def verify_confirm(confirm)
      return unless confirm

      unless confirm == { "type" => "confirm_subscription", "identifier" => @channel }
        raise "Not a confirm: #{confirm.inspect}"
      end
    end
  end
end
