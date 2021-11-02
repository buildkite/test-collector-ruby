# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

module RSpec::Buildkite::Analytics
  class SocketConnection
    class HandshakeError < StandardError; end
    class SocketError < StandardError; end

    SOCKET_READ_TIMEOUT_SECONDS = 0.1
    SOCKET_READ_UPTO_BYTES = 4096

    def initialize(url, headers)
      uri = URI.parse(url)
      protocol = "http"

      begin
        socket = TCPSocket.new(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80))

        if uri.scheme == "wss"
          ctx = OpenSSL::SSL::SSLContext.new
          protocol = "https"

          ctx.min_version = :TLS1_2
          ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
          ctx.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

          socket = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          socket.connect
        end
      rescue
        # We are rescuing all here, as there are a range of Errno errors that could be
        # raised when we fail to establish a TCP connection
        raise SocketError
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

      # The errors below are raised when we establish the TCP connection, but get back
      # an error, i.e. in dev we can still connect to puma-dev while nginx isn't
      # running, or in prod we can hit a load balancer while app is down
      unless handshake.valid?
        case handshake.error
        when Exception, String
          raise HandshakeError.new(handshake.error)
        when nil
          raise HandshakeError.new("Invalid handshake")
        else
          raise HandshakeError.new(handshake.error.inspect)
        end
      end

      @version = handshake.version

      @frame = WebSocket::Frame::Incoming::Client.new
    end

    # If a new message from the server is available, read it from the socket. Otherwise return
    # nil. This won't block waiting for a message.
    def next_message
      # TODO why would there be no socket?
      raise "oh no, no socket" if @socket.nil?

      if data = @frame.next
        return JSON.parse(data.data)
      end

      ready = IO.select([@socket], nil, nil, SOCKET_READ_TIMEOUT_SECONDS)

      # IO.readpartial will block if no data is ready to read, so only call it when IO.select has
      # said there's data waiting for us. We're read *up to* the requested number of bytes if they're
      # available, but won't wait for exactly that many
      if ready
        @frame << @socket.readpartial(SOCKET_READ_UPTO_BYTES)
      end

      if data = @frame.next
        return JSON.parse(data.data)
      end
    end

    def transmit(data, type: :text)
      # this line prevents us from calling disconnect twice
      return if @socket.nil?

      raw_data = data.to_json
      frame = WebSocket::Frame::Outgoing::Client.new(data: raw_data, type: :text, version: @version)
      @socket.write(frame.to_s)
    rescue Errno::EPIPE, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      return unless @socket
      @session.logger.write("got #{e}, attempting disconnected flow")
      disconnect
    end

    def close
      @session.logger.write("socket close")
      transmit(nil, type: :close)
      disconnect
    end

    private

    def disconnect
      @session.logger.write("socket disconnect")
      socket = @socket
      @socket = nil
      socket&.close
    end
  end
end
