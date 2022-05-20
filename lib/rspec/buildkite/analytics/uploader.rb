# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require "net/http"
require "openssl"
require "websocket"

require_relative "trace"
require_relative "tracer"
require_relative "network"
require_relative "object"
require_relative "session"
require_relative "reporter"
require_relative "ci"

require "active_support"
require "active_support/notifications"

require "securerandom"

module RSpec::Buildkite::Analytics
  class Uploader
    def self.traces
      @traces ||= {}
    end

    REQUEST_EXCEPTIONS = [
      URI::InvalidURIError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      Net::ReadTimeout,
      Net::OpenTimeout,
      OpenSSL::SSL::SSLError,
      OpenSSL::SSL::SSLErrorWaitReadable,
      EOFError
    ]

    def self.configure
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

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end
  end
end
