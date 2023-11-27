# frozen_string_literal: true

require "net/http"

module Buildkite::TestCollector
  class HTTPClient
    def initialize(url)
      @url = url
      @authorization_header = "Token token=\"#{Buildkite::TestCollector.api_token}\""
    end

    def post_json(data)
      instructions = prepare_upload

      # TODO: rethink the data structure.
      # This is what was being posted to the API, but now we're uploading direct to storage.
      # Perhaps just a more efficient representation of data?
      # Or do we need some/all of run_env to identify the upload/run?
      # Perhaps that can be entirely encoded in the key.
      # Ideally something efficient/binary, but probably stick with Ruby's stdlib, probably JSON.
      payload = JSON.generate(
        run_env: Buildkite::TestCollector::CI.env,
        format: "json",
        data: data.map(&:as_hash),
      )

      compressed_body = StringIO.new

      gz = Zlib::GzipWriter.new(compressed_body)
      gz.write(payload)
      gz.close

      request = instructions.method.new(instructions.url.path, {
        "Content-Type" => instructions.content_type,
        "Content-Encoding" => "gzip",
      })

      request.body = compressed_body.string

      http = Net::HTTP.new(instructions.url.host, instructions.url.port)
      http.use_ssl = instructions.url.scheme == "https"
      http.request(request)
    end

    def metadata
      url = URI.parse("#{url}/metadata")

      request = Net::HTTP::Get.new(url.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json"
      })

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      http.request(request)
    end

    private

    attr_reader :url
    attr_reader :authorization_header

    def prepare_upload
      url = URI.parse(Buildkite::TestCollector.upload_prepare_url)

      request = Net::HTTP::Post.new(url.path, {
        "Authorization" => authorization_header,
        "Content-Type" => "application/json",
      })

      request.body = JSON.generate(
        run_env: Buildkite::TestCollector::CI.env,
        format: "json",
      )

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = url.scheme == "https"
      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        # TODO: error handling
      end

      unless response.content_type == "application/json"
        # TODO: error handling
      end

      data = JSON.parse(response.body).fetch("upload")

      UploadInstructions.new(
        data.fetch("method"),
        data.fetch("url"),
        data.fetch("content_type"),
      )
    end

    class UploadInstructions
      def initialize(method:, url:, content_type:)
        @method = method
        @url = url
        @content_type = content_type
      end

      def method
        case @method.upcase
        when "POST" then Net::HTTP::Post
        when "PUT" then Net::HTTP::Put
        else raise "Invalid method: #{method}"
        end
      end

      def url
        @parsed_url ||= URI.parse(@url)
      end

      attr_reader :content_type
    end
  end
end
