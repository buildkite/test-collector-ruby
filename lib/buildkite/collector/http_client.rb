# frozen_string_literal: true

module Buildkite::Collector
  class HTTPClient
    def self.post(url)
      contact_uri = URI.parse(url)

      http = Net::HTTP.new(contact_uri.host, contact_uri.port)
      http.use_ssl = contact_uri.scheme == "https"

      authorization_header = "Token token=\"#{Buildkite::Collector.api_token}\""

      contact = Net::HTTP::Post.new(contact_uri.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json",
      })
      contact.body = {
        run_env: Buildkite::Collector::CI.env,
        format: "websocket"
      }.to_json

      http.request(contact)
    end
  end
end
