# frozen_string_literal: true

require "rspec/buildkite/analytics/session"
require "rspec/buildkite/analytics/socket_connection"

RSpec.describe "RSpec::Buildkite::Analytics::Session" do
  let(:socket_double) { instance_double("RSpec::Buildkite::Analytics::SocketConnection") }
  let(:session) { RSpec::Buildkite::Analytics::Session.new("fake_url", "fake_auth", "fake_channel") }

  before do
    # mock the SocketConnection new method to send the welcome message
    allow(RSpec::Buildkite::Analytics::SocketConnection).to receive(:new) { |session, _, _|
      @session = session
      @session.handle(socket_double, {"type"=> "welcome"}.to_json)
      socket_double
    }

    # mock responding to the subscribe message with the appropriate response
    allow(socket_double).to receive(:transmit).with({
      "command" => "subscribe",
      "identifier" => "fake_channel"
    }) { @session.handle(socket_double, {"type"=> "confirm_subscription", "identifier"=> "fake_channel"}.to_json) }

    stub_const("RSpec::Buildkite::Analytics::Session::WAIT_BETWEEN_RECONNECTIONS", 0)
    stub_const("RSpec::Buildkite::Analytics::Session::CONFIRMATION_TIMEOUT", 5)
  end

  describe "#initalize" do
    before do
      # mock the SocketConnection new method to send the confirm message, when it should be sending the welcome
      allow(RSpec::Buildkite::Analytics::SocketConnection).to receive(:new) { |session, _, _|
        @session = session
        @session.handle(socket_double, {"type"=> "confirm_subscription"}.to_json)
        socket_double
      }
    end

    it "does not raise errors if there is a problem in initialization" do
      expect{session}.not_to raise_error
    end
  end

  describe "#handle" do
    it "processes confirmations from the server" do
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:1]", {"hi"=> "thing"})

      expect(session.unconfirmed_idents_count).to be 1
      session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/analytics/session_spec.rb[1:1]"]}}.to_json)
      expect(session.unconfirmed_idents_count).to be 0
    end
  end

  describe "#close" do
    it "waits until the unconfirmed_idents is empty" do
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:1]", {"hi"=> "thing"})
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:2]", {"hi"=> "thing"})

      expect(socket_double).to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      }) { Thread.new do sleep(1); session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/analytics/session_spec.rb[1:1]", "./spec/analytics/session_spec.rb[1:2]"]}}.to_json) end }

      expect(socket_double).to receive(:close)
      expect(session.instance_variable_get(:@empty)).to receive(:wait).and_call_original

      session.close()
    end

    it "doesn't wait if the unconfirmed_idents is already empty" do
      expect(socket_double).to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      })

      expect(socket_double).to receive(:close)
      expect(session.instance_variable_get(:@empty)).not_to receive(:wait)

      session.close()
    end

    it "waits for multiple confirmation messages from server" do
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:1]", {"hi"=> "thing"})
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:2]", {"hi"=> "thing"})

      expect(socket_double).to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      }) { Thread.new do sleep(1); session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/analytics/session_spec.rb[1:2]"]}}.to_json) end; Thread.new do sleep(2); session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/analytics/session_spec.rb[1:2]"]}}.to_json) end}

      expect(session.instance_variable_get(:@empty)).to receive(:wait).and_call_original

      expect(session).to receive(:remove_unconfirmed_idents).exactly(2).times

      expect(socket_double).to receive(:close)

      session.close()
    end
  end

  describe "#write_result" do
    let(:fake_trace) { instance_double("RSpec::Buildkite::Analytics::Uploader::Trace") }
    let(:fake_trace_id) { "33569b01-4180-4416-9631-c25d370a4c96" }
    let(:trace_json) do
      {
        id: fake_trace_id,
        identifier: "./spec/analytics/session_spec.rb[1:2]"
      }.to_json
    end

    before do
      allow(fake_trace).to receive(:as_json).and_return(trace_json)
      allow(fake_trace).to receive(:id).and_return(fake_trace_id)
    end

    it "sends the result to the server" do
      expect(socket_double).to receive(:transmit).with({
        "identifier" => "fake_channel",
        "command" => "message",
        "data" => {
          "action" => "record_results",
          "results" => [trace_json]
          }.to_json
      })

      session.write_result(fake_trace)
    end

    it "stores the sent result" do
      expect(session.unconfirmed_idents_count).to eq 0

      expect(socket_double).to receive(:transmit).with({
        "identifier" => "fake_channel",
        "command" => "message",
        "data" => {
          "action" => "record_results",
          "results" => [trace_json]
          }.to_json
      })

      session.write_result(fake_trace)

      expect(session.unconfirmed_idents_count).to eq 1
    end
  end

  describe "#disconnected" do
    it "does a reconnect and redoes the socket" do
      session.disconnected(socket_double)

      expect(RSpec::Buildkite::Analytics::SocketConnection).to have_received(:new).twice
    end

    it "retries reconnection if it gets a handshake error" do
      # stub connection so that it is successful the first time, then raises an error,
      # and then is successful again
      call_count = 0
      allow(RSpec::Buildkite::Analytics::SocketConnection).to receive(:new) { |session, _, _|
        call_count += 1
        if call_count.odd?
          @session = session
          @session.handle(socket_double, {"type"=> "welcome"}.to_json)
          socket_double
        else
          raise RSpec::Buildkite::Analytics::SocketConnection::HandshakeError
        end
      }

      session.disconnected(socket_double)

      # This expectation is for 3 times because the socket connects initially, then
      # after disconnection there is one connection attempt that throws an error,
      # and then the retry of the connection is successful
      expect(RSpec::Buildkite::Analytics::SocketConnection)
        .to have_received(:new).exactly(3).times
    end

    it "retries reconnection if it gets a socket error" do
      # stub connection so that it is successful the first time, then raises an error,
      # and then is successful again
      call_count = 0
      allow(RSpec::Buildkite::Analytics::SocketConnection).to receive(:new) { |session, _, _|
        call_count += 1
        if call_count.odd?
          @session = session
          @session.handle(socket_double, {"type"=> "welcome"}.to_json)
          socket_double
        else
          raise RSpec::Buildkite::Analytics::SocketConnection::SocketError
        end
      }

      session.disconnected(socket_double)

      # This expectation is for 3 times because the socket connects initially, then
      # after disconnection there is one connection attempt that throws an error,
      # and then the retry of the connection is successful
      expect(RSpec::Buildkite::Analytics::SocketConnection)
        .to have_received(:new).exactly(3).times
    end

    it "retries reconnection if it gets a rejected subscription error" do
      # stub transmit response so that it is successful the first time, then raises an error,
      # and then is successful again
      call_count = 0
      allow(socket_double).to receive(:transmit).with({
        "command" => "subscribe",
        "identifier" => "fake_channel"
      }) {
          call_count += 1
          if call_count.odd?
            @session.handle(socket_double, {"type"=> "confirm_subscription", "identifier"=> "fake_channel"}.to_json)
          else
            raise RSpec::Buildkite::Analytics::Session::RejectedSubscription
          end
      }

      session.disconnected(socket_double)

      # This expectation is for 3 times because the socket connects initially, then
      # after disconnection there is one connection attempt that throws an error,
      # and then the retry of the connection is successful
      expect(RSpec::Buildkite::Analytics::SocketConnection)
        .to have_received(:new).exactly(3).times
    end

    it "retries reconnection if it gets a timeout error" do
      # stub pop_with_timeout so that it raises the timeout error, and then gives back
      # the two expected welcome and subscribe messages
      call_count = 0
      allow(session).to receive(:pop_with_timeout) {
        call_count += 1
        case call_count
        when 1
          raise RSpec::Buildkite::Analytics::TimeoutError
        when 2
          { "type" => "welcome" }
        when 3
          { "type" => "confirm_subscription", "identifier" => "fake_channel" }
        end
      }

      session.disconnected(socket_double)

      # This expectation is for 3 times because the socket connects initially, then
      # after disconnection there is one connection attempt that throws an error,
      # and then the retry of the connection is successful
      expect(RSpec::Buildkite::Analytics::SocketConnection)
        .to have_received(:new).exactly(3).times
    end

    it "retransmits if there are unconfirmed idents in the buffer" do
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:1]", {"identifier"=> "./spec/analytics/session_spec.rb[1:1]", "hi"=> "thing"})

      expect(socket_double).to receive(:transmit)
        .with({
          "command" => "message",
          "identifier" => "fake_channel",
          "data" => {
            "action" => "record_results",
            "results" => [{
              "identifier"=> "./spec/analytics/session_spec.rb[1:1]",
              "hi" => "thing"
            }]}.to_json
        })

      session.disconnected(socket_double)
    end

    it "doesn't retransmit if there are no unconfirmed idents" do
      expect(session.unconfirmed_idents_count).to eq 0

      expect(socket_double).not_to receive(:transmit)
        .with(hash_including("command" => "message", "identifier" => "fake_channel"))

      session.disconnected(socket_double)
    end

    it "doesn't transmit eot if session has not closed" do
      expect(socket_double).not_to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      })

      session.disconnected(socket_double)
    end

    it "resends idents followed by eot if tests have finished" do
      session.send(:add_unconfirmed_idents, "./spec/analytics/session_spec.rb[1:1]", {"identifier"=> "./spec/analytics/session_spec.rb[1:1]", "hi"=> "thing"})

      # In this test the order of operations is:
      # 1. first eot is sent, spawn a new thread to simulate the disconnect
      # 2. disconnect thread will send the unconfirmed idents
      # 3. disconnect thread will send another eot, and the server will respond with confirm
      # 4. socket closes
      #
      # However due to the way that the responses need to be mocked on the
      # methods, they don't appear in the order above

      # resend idents
      expect(socket_double).to receive(:transmit)
        .with({
          "command" => "message",
          "identifier" => "fake_channel",
          "data" => {
            "action" => "record_results",
            "results" => [{
              "identifier"=> "./spec/analytics/session_spec.rb[1:1]",
              "hi" => "thing"
            }]}.to_json
        })

      # mocking eot response
      call_count = 0
      # expect transmit to be called twice
      expect(socket_double).to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      }).twice {
        call_count += 1
        if call_count == 1
          # simulate getting a disconnected socket after sending first eot
          Thread.new do session.disconnected(socket_double) end
        else
          # respond to the second eot with confirmation of idents
          session.handle(socket_double, {
            "type"=> "message",
            "identifier"=> "fake_channel",
            "message" => {
              "confirm"=> [
                "./spec/analytics/session_spec.rb[1:1]",
                "./spec/analytics/session_spec.rb[1:2]"
            ]}
          }.to_json)
        end
      }

      expect(socket_double).to receive(:close)

      session.close
    end

    it "raises error if it can't reconnect after 3 goes" do
      call_count = 0
      allow(RSpec::Buildkite::Analytics::SocketConnection).to receive(:new) { |session, _, _|
        call_count += 1
        # let the initial connection be successful
        if call_count == 1
          @session = session
          @session.handle(socket_double, {"type"=> "welcome"}.to_json)
          socket_double
        else
          # every other connection attempt will raise an error
          raise RSpec::Buildkite::Analytics::SocketConnection::SocketError
        end
      }

      expect { session.disconnected(socket_double) }.to raise_error(RSpec::Buildkite::Analytics::SocketConnection::SocketError)

      # This expectation is for 5 times because the socket connects initially, then it has 3 retries, then on the fourth retry the error is thrown
      expect(RSpec::Buildkite::Analytics::SocketConnection).to have_received(:new).exactly(5).times
    end
  end
end
