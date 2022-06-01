# frozen_string_literal: true

module Buildkite::Collector
  class HTTPClient
    attr :authorization_header
    def initialize(url)
      @url = url
      @authorization_header = "Token token=\"#{Buildkite::Collector.api_token}\""
    end

    def post
      contact_uri = URI.parse(url)

      http = Net::HTTP.new(contact_uri.host, contact_uri.port)
      http.use_ssl = contact_uri.scheme == "https"

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

    private

    attr :url
  end
end
