# frozen_string_literal: true

require "websocket"
require "buildkite/collector/session"
require "buildkite/collector/socket_connection"

RSpec.describe Buildkite::Collector::SocketConnection do
  let(:session_double) { instance_double("Buildkite::Collector::Session") }
  let(:socket_connection) { Buildkite::Collector::SocketConnection.new(session_double, "fake_url", {}) }
  let(:ssl_socket_double) { instance_double("OpenSSL::SSL::SSLSocket") }
  let(:tcp_socket_double) { instance_double("TCPSocket") }
  let(:handshake_double) { instance_double("WebSocket::Handshake::Client") }
  let(:frame_double) { instance_double("WebSocket::Frame::Outgoing::Client") }

  before do
    allow(TCPSocket).to receive(:new).and_return(tcp_socket_double)

    allow(URI).to receive(:parse).and_return(OpenStruct.new(scheme: "wss", host: 3000, port: 443))

    allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl_socket_double)
    allow(ssl_socket_double).to receive(:connect)
    allow(ssl_socket_double).to receive(:readpartial)
    allow(ssl_socket_double).to receive(:close)

    allow(WebSocket::Handshake::Client).to receive(:new).and_return(handshake_double)
    allow(handshake_double).to receive(:finished?).and_return(true)
    allow(handshake_double).to receive(:valid?).and_return(true)
    allow(handshake_double).to receive(:version).and_return("12")

    allow(WebSocket::Frame::Outgoing::Client).to receive(:new).and_return(frame_double)
    allow(frame_double).to receive(:to_s).and_return("hi")
  end

  describe "#transmit" do
    it "calls disconnected if it gets an SSL error" do
      write_call_count = 0
      allow(ssl_socket_double).to receive(:write) {
        write_call_count += 1
        # the first write is part of the handshaking process, so let it succeed
        if write_call_count == 1
          nil
        else
          raise OpenSSL::SSL::SSLError
        end
      }

      expect(session_double).to receive(:disconnected)
      socket_connection.transmit("hi")
    end

    it "calls disconnected if it gets an IndexError" do
      write_call_count = 0
      allow(ssl_socket_double).to receive(:write) {
        write_call_count += 1
        # the first write is part of the handshaking process, so let it succeed
        if write_call_count == 1
          nil
        else
          raise IndexError
        end
      }

      expect(session_double).to receive(:disconnected)
      socket_connection.transmit("hi")
    end
  end
end
