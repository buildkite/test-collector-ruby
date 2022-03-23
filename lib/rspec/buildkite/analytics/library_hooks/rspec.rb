require "rspec/core"
require "rspec/expectations"

require_relative "../uploader"

RSpec::Buildkite::Analytics.uploader = RSpec::Buildkite::Analytics::Uploader

RSpec.configure do |config|
  config.before(:suite) do
    config.add_formatter RSpec::Buildkite::Analytics::Reporter

    if RSpec::Buildkite::Analytics.api_token
      contact_uri = URI.parse(RSpec::Buildkite::Analytics.url)

      http = Net::HTTP.new(contact_uri.host, contact_uri.port)
      http.use_ssl = contact_uri.scheme == "https"

      authorization_header = "Token token=\"#{RSpec::Buildkite::Analytics.api_token}\""

      contact = Net::HTTP::Post.new(contact_uri.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json",
      })
      contact.body = {
        run_env: RSpec::Buildkite::Analytics::CI.env,
        format: "websocket"
      }.to_json

      response = begin
        http.request(contact)
      rescue *RSpec::Buildkite::Analytics::REQUEST_EXCEPTIONS => e
        puts "Buildkite Test Analytics: Error communicating with the server: #{e.message}"
      end

      return unless response

      case response.code
      when "401"
        puts "Buildkite Test Analytics: Invalid Suite API key. Please double check your Suite API key."
      when "200"
        json = JSON.parse(response.body)

        if (socket_url = json["cable"]) && (channel = json["channel"])
          RSpec::Buildkite::Analytics.session = RSpec::Buildkite::Analytics::Session.new(socket_url, authorization_header, channel)
        end
      else
        request_id = response.to_hash["x-request-id"]
        puts "rspec-buildkite-analytics could not establish an initial connection with Buildkite. You may be missing some data for this test suite, please contact support."
      end
    else
      if !!ENV["BUILDKITE_BUILD_ID"]
        puts "Buildkite Test Analytics: No Suite API key provided. You can get the API key from your Suite settings page."
      end
    end
  end

  config.around(:each) do |example|
    tracer = RSpec::Buildkite::Analytics::Tracer.new

    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
    example.run
    Thread.current[:_buildkite_tracer] = nil

    tracer.finalize

    trace = RSpec::Buildkite::Analytics::Uploader::Trace.new(example, tracer.history)
    RSpec::Buildkite::Analytics.uploader.traces << trace
  end
end

RSpec::Buildkite::Analytics::Network.configure
RSpec::Buildkite::Analytics::Object.configure

ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
  RSpec::Buildkite::Analytics::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
end
