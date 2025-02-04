# frozen_string_literal: true

require "net/http"

module Buildkite::TestCollector
  class HTTPClient
    def initialize(url:, api_token:)
      @url = url
      @api_token = api_token
    end

    def post_upload(data:, run_env:, tags:)
      endpoint_uri = URI.parse(url)

      http = Net::HTTP.new(endpoint_uri.host, endpoint_uri.port)
      http.use_ssl = endpoint_uri.scheme == "https"

      request = Net::HTTP::Post.new(endpoint_uri.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json",
        "Content-Encoding" => "gzip",
      })

      data_set = data.map(&:as_hash)

      body = {
        run_env: run_env,
        tags: tags,
        format: "json",
        data: data_set
      }.to_json

      compressed_body = StringIO.new

      writer = Zlib::GzipWriter.new(compressed_body)
      writer.write(body)
      writer.close

      request.body = compressed_body.string

      response = http.request(request)

      if response.is_a?(Net::HTTPSuccess)
        response
      else
        raise "HTTP Request Failed: #{response.code} #{response.message}"
      end
    end

    def metadata
      endpoint_uri = URI.parse("#{url}/metadata")

      http = Net::HTTP.new(endpoint_uri.host, endpoint_uri.port)
      http.use_ssl = endpoint_uri.scheme == "https"

      request = Net::HTTP::Get.new(endpoint_uri.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json"
      })

      http.request(request)
    end

    private

    attr_reader :url

    def authorization_header
      "Token token=\"#{@api_token}\""
    end
  end
end
