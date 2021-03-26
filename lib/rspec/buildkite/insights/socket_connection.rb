# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

module RSpec::Buildkite::Insights
  class SocketConnection
    def initialize(session, url, headers)
      uri = URI.parse(url)
      @session = session
      protocol = "http"
      socket = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))

      if uri.scheme == "wss"
        ctx = OpenSSL::SSL::SSLContext.new
        protocol = "https"

        # FIXME: Are any of these needed / not defaults?
        #ctx.min_version = :TLS1_2
        #ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        #ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

        socket = OpenSSL::SSL::SSLSocket.new(socket, ctx)
        socket.connect
      end

      @socket = socket

      headers = { "Origin" => "#{protocol}://#{uri.host}" }.merge(headers)
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
end
