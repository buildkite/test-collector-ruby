# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require "openssl"
require "websocket"

require_relative "tracer"

require_relative "network"

require "active_support"
require "active_support/notifications"

require "securerandom"

module RSpec::Buildkite::Insights
  class Uploader
    class Trace
      attr_reader :example, :history
      def initialize(example, history)
        @example = example
        @history = history
      end

      def failure_message
        case example.exception
        when RSpec::Expectations::ExpectationNotMetError
          example.exception.message
        when Exception
          "#{example.exception.class}: #{example.exception.message}"
        end
      end

      def result_state
        case example.execution_result.status
        when :passed; "passed"
        when :failed; "failed"
        when :pending; "skipped"
        end
      end

      def as_json
        {
          scope: example.example_group.metadata[:full_description],
          name: example.description,
          identifier: example.id,
          location: example.location,
          result: result_state,
          failure: failure_message,
          history: history,
        }
      end
    end

    class SocketConnection
      def initialize(session, url, headers)
        uri = URI.parse(url)
        @session = session

        socket = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))

        if uri.scheme == "wss"
          ctx = OpenSSL::SSL::SSLContext.new

          # FIXME: Are any of these needed / not defaults?
          #ctx.min_version = :TLS1_2
          #ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
          #ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

          socket = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          socket.connect
        end

        @socket = socket

        headers = { "Origin" => "http://#{uri.host}" }.merge(headers)
        handshake = WebSocket::Handshake::Client.new(url: url, headers: headers)

        @socket.write handshake.to_s

        until handshake.finished?
          if byte = @socket.getc
            handshake << byte
          end
        end

        unless handshake.valid?
          case handshake.error
          when Exception, String
            raise handshake.error
          when nil
            raise "Invalid handshake"
          else
            raise handshake.error.inspect
          end
        end

        @version = handshake.version

        @thread = Thread.new do
          frame = WebSocket::Frame::Incoming::Client.new

          while @socket
            frame << @socket.readpartial(4096)

            while data = frame.next
              @session.handle(self, data.data)
            end
          end
        rescue EOFError
          @session.disconnected(self)
          disconnect
        end

        @session.connected(self)
      end

      def transmit(data, type: :text)
        raw_data = data.to_json
        frame = WebSocket::Frame::Outgoing::Client.new(data: raw_data, type: :text, version: @version)
        @socket.write(frame.to_s)
      rescue Errno::EPIPE
        @session.disconnected(self)
        disconnect
      end

      def close
        transmit(nil, type: :close)
        disconnect
      end

      private

      def disconnect
        @socket.close
        @socket = nil

        @thread&.kill
      end
    end

    class Session
      def initialize(url, authorization_header, channel)
        @queue = Queue.new
        @channel = channel

        @socket = SocketConnection.new(self, url, {
          "Authorization" => authorization_header,
        })

        welcome = @queue.pop
        unless welcome == { "type" => "welcome" }
          raise "Not a welcome: #{welcome.inspect}"
        end

        @socket.transmit({ "command" => "subscribe", "identifier" => @channel })

        confirm = @queue.pop
        unless confirm == { "type" => "confirm_subscription", "identifier" => @channel }
          raise "Not a confirm: #{confirm.inspect}"
        end
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
    end

    def self.traces
      @traces ||= []
    end

    def self.configure
      uploader = self
      session = nil

      RSpec.configure do |config|
        config.around(:each) do |example|
          tracer = RSpec::Buildkite::Insights::Tracer.new

          Thread.current[:_buildkite_tracer] = tracer
          example.run
          Thread.current[:_buildkite_tracer] = nil

          tracer.finalize

          trace = RSpec::Buildkite::Insights::Uploader::Trace.new(example, tracer.history)
          uploader.traces << trace

          session&.write_result(trace)
        end

        config.before(:suite) do
          if RSpec::Buildkite::Insights.api_token
            contact_uri = URI.parse(RSpec::Buildkite::Insights.url)

            http = Net::HTTP.new(contact_uri.host, contact_uri.port)
            http.use_ssl = contact_uri.scheme == "https"

            authorization_header = "Token token=\"#{RSpec::Buildkite::Insights.api_token}\""

            contact = Net::HTTP::Post.new(contact_uri.path, {
              "Authorization" => authorization_header,
              "Content-Type" => "application/json",
            })
            contact.body = {
              # FIXME: Unique identifying attributes of the current build
              run_key: ENV["BUILDKITE_BUILD_ID"] || SecureRandom.uuid,
            }.to_json

            response = http.request(contact)

            if response.is_a?(Net::HTTPSuccess)
              json = JSON.parse(response.body)

              if (socket_url = json["cable"]) && (channel = json["channel"])
                session = Session.new(socket_url, authorization_header, channel)
              end
            end
          end
        end

        config.after(:suite) do
          if filename = RSpec::Buildkite::Insights.filename
            data_set = { results: uploader.traces.map(&:as_json) }

            File.open(filename, "wb") do |f|
              gz = Zlib::GzipWriter.new(f)
              gz.write(data_set.to_json)
              gz.close
            end
          end
        end
      end

      RSpec::Buildkite::Insights::Network.configure

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        tracer&.backfill(:sql, finish - start, { query: payload[:sql] })
      end
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end
  end
end
