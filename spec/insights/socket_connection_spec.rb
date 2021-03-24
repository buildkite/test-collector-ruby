# frozen_string_literal: true

require "websocket"
require "rspec/buildkite/insights/session"
require "rspec/buildkite/insights/socket_connection"

RSpec.describe "RSpec::Buildkite::Insights::SocketConnection" do
  let(:auth_header) { { "Authorization" => %(Token token="123") } }
  let(:fake_handshake) { double(:finished? => true, valid?: true, version: "1") }

  it "send the headers with https protocol for wss websocket" do
    url = "wss://buildkite.localhost/_cable"
    allow(WebSocket::Handshake::Client).to receive(:new) { fake_handshake }
    session = double("Session", connected: "OK", verify_welcome: "", verify_confirm: "")

    socket_connection = RSpec::Buildkite::Insights::SocketConnection.new(session, url, auth_header)

    expect(WebSocket::Handshake::Client).to have_received(:new).with(
      {
        headers: { "Authorization"=>"Token token=\"123\"", "Origin"=>"https://buildkite.localhost" },
        url: "wss://buildkite.localhost/_cable"
      }
    )
  end

  it "send the headers with http protocol for ws websocket" do
    url = "ws://buildkite.localhost/_cable"
    allow(WebSocket::Handshake::Client).to receive(:new) { fake_handshake }
    session = double("Session", connected: "OK", verify_welcome: "", verify_confirm: "")

    socket_connection = RSpec::Buildkite::Insights::SocketConnection.new(session, url, auth_header)

    expect(WebSocket::Handshake::Client).to have_received(:new).with(
      {
        headers: { "Authorization"=>"Token token=\"123\"", "Origin"=>"http://buildkite.localhost" },
        url: "ws://buildkite.localhost/_cable"
      }
    )
  end
end
