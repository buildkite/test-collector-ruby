# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

module Buildkite::Collector
  class SocketConnection
    class HandshakeError < StandardError; end
    class SocketError < StandardError; end

    def initialize(session, url, headers)
      uri = URI.parse(url)
      @session = session
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

      # Setting up a new thread that listens on the socket, and processes incoming
      # comms from the server
      @thread = Thread.new do
        Buildkite::Collector.logger.debug("listening in on socket")
        frame = WebSocket::Frame::Incoming::Client.new

        while @socket
          frame << @socket.readpartial(4096)

          while data = frame.next
            @session.handle(self, data.data)
          end
        end
      rescue EOFError, Errno::ECONNRESET => e
        Buildkite::Collector.logger.error("#{e}")
        if @socket
          Buildkite::Collector.logger.error("attempting disconnected flow")
          @session.disconnected(self)
          disconnect
        end
      rescue IOError
        # This is fine to ignore
        Buildkite::Collector.logger.error("IOError")
      rescue IndexError
        # I don't like that we're doing this but I think it's the best of the options
        #
        # This relates to this issue https://github.com/ruby/openssl/issues/452
        # A fix for it has been released but the repercussions of overriding
        # the OpenSSL version in the stdlib seem worse than catching this error here.
        Buildkite::Collector.logger.error("IndexError")
        if @socket
          Buildkite::Collector.logger.error("attempting disconnected flow")
          @session.disconnected(self)
          disconnect
        end
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
      return if type == :close
      Buildkite::Collector.logger.error("got #{e}, attempting disconnected flow")
      @session.disconnected(self)
      disconnect
    rescue IndexError
      # I don't like that we're doing this but I think it's the best of the options
      #
      # This relates to this issue https://github.com/ruby/openssl/issues/452
      # A fix for it has been released but the repercussions of overriding
      # the OpenSSL version in the stdlib seem worse than catching this error here.
      Buildkite::Collector.logger.error("IndexError")
      if @socket
        Buildkite::Collector.logger.error("attempting disconnected flow")
        @session.disconnected(self)
        disconnect
      end
    end

    def close
      Buildkite::Collector.logger.debug("socket close")
      transmit(nil, type: :close)
      disconnect
    end

    private

    def disconnect
      Buildkite::Collector.logger.debug("socket disconnect")
      socket = @socket
      @socket = nil
      socket&.close
      @thread&.join unless @thread == Thread.current
    end
  end
end
