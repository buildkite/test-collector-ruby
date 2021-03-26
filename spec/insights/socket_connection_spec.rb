# frozen_string_literal: true

require "websocket"
require "rspec/buildkite/insights/session"
require "rspec/buildkite/insights/socket_connection"

RSpec.describe "RSpec::Buildkite::Insights::SocketConnection" do
  xit "send the headers with https protocol for wss websocket"
  xit "send the headers with http protocol for ws websocket"
end
