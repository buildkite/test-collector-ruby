# frozen_string_literal: true

require "rspec/buildkite/insights/session"

RSpec.describe RSpec::Buildkite::Insights::Session do
  def new_session
    RSpec::Buildkite::Insights::Session.new(
      "ws://insights.localhost/_cable",
       %(Token token="test"),
       %({"channel":"Insights::UploadChannel","id":"0522b234-f36f-41c6-a35c-123456789012"}),
       timeout: 0.01
    )
  end

  it "timeout if server does not respond in timeout seconds" do
    fake_connection = double
    allow(RSpec::Buildkite::Insights::SocketConnection).to receive(:new) { fake_connection }

    expect { new_session }.to raise_error(RSpec::Buildkite::Insights::TimeoutError)
  end
end
