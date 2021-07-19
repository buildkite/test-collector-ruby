# frozen_string_literal: true

require "rspec/buildkite/insights/session"
require "rspec/buildkite/insights/socket_connection"

RSpec.describe "RSpec::Buildkite::Insights::Session" do
  let(:socket_double) { instance_double("RSpec::Buildkite::Insights::SocketConnection") }
  let(:session) { RSpec::Buildkite::Insights::Session.new("fake_url", "fake_auth", "fake_channel") }

  before do
    # mock the SocketConnection new method to send the welcome message
    allow(RSpec::Buildkite::Insights::SocketConnection).to receive(:new) { |session, _, _|
      @session = session
      @session.handle(socket_double, {"type"=> "welcome"}.to_json)
      socket_double
    }

    # mock responding to the subscribe message with the appropriate response
    allow(socket_double).to receive(:transmit).with({
      "command" => "subscribe",
      "identifier" => "fake_channel"
    }) { @session.handle(socket_double, {"type"=> "confirm_subscription", "identifier"=> "fake_channel"}.to_json) }
  end

  describe "#handle" do
    it "processes confirmations from the server" do
      session.send(:add_unconfirmed_idents, "./spec/insights/session_spec.rb[1:1]", {"hi"=> "thing"})

      expect(session.unconfirmed_idents_count).to be 1
      session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/insights/session_spec.rb[1:1]"]}}.to_json)
      expect(session.unconfirmed_idents_count).to be 0
    end
  end

  describe "#close" do
    before do
      stub_const("RSpec::Buildkite::Insights::Session::CONFIRMATION_TIMEOUT", 5)
    end

    it "waits until the unconfirmed_idents is empty" do
      session.send(:add_unconfirmed_idents, "./spec/insights/session_spec.rb[1:1]", {"hi"=> "thing"})
      session.send(:add_unconfirmed_idents, "./spec/insights/session_spec.rb[1:2]", {"hi"=> "thing"})

      expect(socket_double).to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      }) { Thread.new do sleep(1); session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/insights/session_spec.rb[1:1]", "./spec/insights/session_spec.rb[1:2]"]}}.to_json) end }

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
      session.send(:add_unconfirmed_idents, "./spec/insights/session_spec.rb[1:1]", {"hi"=> "thing"})
      session.send(:add_unconfirmed_idents, "./spec/insights/session_spec.rb[1:2]", {"hi"=> "thing"})

      expect(socket_double).to receive(:transmit).with({
        "command" => "message",
        "identifier" => "fake_channel",
        "data" => {
          "action" => "end_of_transmission"
        }.to_json
      }) { Thread.new do sleep(1); session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/insights/session_spec.rb[1:2]"]}}.to_json) end; Thread.new do sleep(2); session.handle(socket_double, {"type"=> "message", "identifier"=> "fake_channel", "message" => {"confirm"=> ["./spec/insights/session_spec.rb[1:2]"]}}.to_json) end}

      expect(session.instance_variable_get(:@empty)).to receive(:wait).and_call_original

      expect(session).to receive(:remove_unconfirmed_idents).exactly(2).times

      expect(socket_double).to receive(:close)

      session.close()
    end
  end

  describe "#write_result" do
    let(:fake_trace) { instance_double("RSpec::Buildkite::Insights::Uploader::Trace") }
    let(:trace_json) do
      {
        identifier: "./spec/insights/session_spec.rb[1:2]"
      }.to_json
    end

    before do
      allow(fake_trace).to receive(:as_json).and_return(trace_json)
      allow(fake_trace).to receive_message_chain(:example, :id).and_return("./spec/insights/session_spec.rb[1:2]")
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
end
