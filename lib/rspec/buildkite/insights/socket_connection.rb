# frozen_string_literal: true

require "socket"
require "openssl"
require "json"
require "forwardable"

module RSpec::Buildkite::Insights
  class ConnectionDetail
    attr :url, :uri, :headers

    def initialize(url:, headers:)
      @url = url
      @uri ||= URI.parse(url)
      protocol = secure_connection? ? "https" : "http"
      @headers = { "Origin" => "#{protocol}://#{uri.host}" }.merge(headers)
    end

    def secure_connection?
      uri.scheme == "wss"
    end
  end

  class SocketConnection
    def_delegators :@conn_detail, :url, :uri, :headers

    def initialize(session, url, headers)
      @conn_detail = ConnectionDetail.new(url: url, headers: headers)

      @session = session
      @socket = setup_socket

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
      current_socket.write(frame.to_s)
    rescue Errno::EPIPE
      @session.disconnected(self)
      disconnect
    end

    def close
      transmit(nil, type: :close)
      disconnect
    end

    private

    def current_socket
      @socket || (@socket = setup_socket)
    end

    def setup_socket
      _socket = TCPSocket.new(uri.host, uri.port || (conn_detail.secure_connection? ? 443 : 80))

      if conn_detail.secure_connection?
        ctx = OpenSSL::SSL::SSLContext.new

        # FIXME: Are any of these needed / not defaults?
        #ctx.min_version = :TLS1_2
        #ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
        #ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

        _socket = OpenSSL::SSL::SSLSocket.new(_socket, ctx)
        _socket.connect
      end

      handshake(_socket)

      _socket
    end

    def handshake(socket)
      handshake = WebSocket::Handshake::Client.new(url: url, headers: headers)

      socket.write handshake.to_s

      until handshake.finished?
        if byte = socket.getc
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
    end

    def disconnect
      @socket.close
      @socket = nil

      @thread&.kill
    end
  end
end
