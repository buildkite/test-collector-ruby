# frozen_string_literal: true

require "net/http"

module Buildkite::TestCollector
  class HTTPClient
    attr :authorization_header
    def initialize(url)
      @url = url
      @authorization_header = "Token token=\"#{Buildkite::TestCollector.api_token}\""
    end

    def post_json(data)
      contact_uri = URI.parse(url)

      http = Net::HTTP.new(contact_uri.host, contact_uri.port)
      http.use_ssl = contact_uri.scheme == "https"

      contact = Net::HTTP::Post.new(contact_uri.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json",
        "Content-Encoding" => "gzip",
      })

      data_set = data.map(&:as_hash)

      body = {
        run_env: Buildkite::TestCollector::CI.env,
        format: "json",
        data: data_set
      }.to_json

      compressed_body = StringIO.new

      writer = Zlib::GzipWriter.new(compressed_body)
      writer.write(body)
      writer.close

      contact.body = compressed_body.string

      http.request(contact)
    end

    def summary
      contact_uri = URI.parse(url)

      http = Net::HTTP.new(contact_uri.host, contact_uri.port)
      http.use_ssl = contact_uri.scheme == "https"

      contact = Net::HTTP::Get.new(contact_uri.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json"
      })

      http.request(contact)
    end

    private

    attr :url
  end
end
