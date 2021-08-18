# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require "openssl"
require "websocket"

require_relative "tracer"
require_relative "network"
require_relative "object"
require_relative "session"
require_relative "reporter"
require_relative "ci"

require "active_support"
require "active_support/notifications"

require "securerandom"

module RSpec::Buildkite::Insights
  class Uploader
    class Trace
      attr_accessor :example
      attr_reader :id, :history

      def initialize(example, history)
        @id = SecureRandom.uuid
        @example = example
        @history = history
      end

      def failure_message
        case example.exception
        when RSpec::Expectations::ExpectationNotMetError
          example.exception.message
        when Exception
          "#{example.exception.class}: #{example.exception.message}"
        end
      end

      def result_state
        case example.execution_result.status
        when :passed; "passed"
        when :failed; "failed"
        when :pending; "skipped"
        end
      end

      def as_json
        {
          id: @id,
          scope: example.example_group.metadata[:full_description],
          name: example.description,
          identifier: example.id,
          location: example.location,
          file_name: generate_file_name(example),
          result: result_state,
          failure: failure_message,
          history: history,
        }
      end

      private

      def generate_file_name(example)
        file_path_regex = /^(.*?\.rb)/
        identifier_file_name = example.id[file_path_regex]
        location_file_name = example.location[file_path_regex]

        if identifier_file_name != location_file_name
          # If the identifier and location files are not the same, we assume
          # that the test was run as part of a shared example. If this isn't the
          # case, then there's something we haven't accounted for
          if example.metadata[:shared_group_inclusion_backtrace].any?
            # Taking the last frame in this backtrace will give us the original
            # entry point for the shared example
            example.metadata[:shared_group_inclusion_backtrace].last.inclusion_location[file_path_regex]
          else
            "Unknown"
          end
        else
          identifier_file_name
        end
      end
    end

    def self.traces
      @traces ||= []
    end

    def self.configure
      RSpec::Buildkite::Insights.uploader = self

      RSpec.configure do |config|
        config.before(:suite) do
          config.add_formatter RSpec::Buildkite::Insights::Reporter

          if RSpec::Buildkite::Insights.api_token
            contact_uri = URI.parse(RSpec::Buildkite::Insights.url)

            http = Net::HTTP.new(contact_uri.host, contact_uri.port)
            http.keep_alive_timeout = 30
            http.use_ssl = contact_uri.scheme == "https"

            authorization_header = "Token token=\"#{RSpec::Buildkite::Insights.api_token}\""

            contact = Net::HTTP::Post.new(contact_uri.path, {
              "Authorization" => authorization_header,
              "Content-Type" => "application/json",
            })
            contact.body = {
              run_env: CI.env
            }.to_json

            response = http.request(contact)

            if response.is_a?(Net::HTTPSuccess)
              json = JSON.parse(response.body)

              if (socket_url = json["cable"]) && (channel = json["channel"])
                RSpec::Buildkite::Insights.session = Session.new(socket_url, authorization_header, channel)
              end
            end
          end
        end

        config.around(:each) do |example|
          tracer = RSpec::Buildkite::Insights::Tracer.new

          # The _buildkite prefix here is added as a safeguard against name collisions
          # as we are in the main thread
          Thread.current[:_buildkite_tracer] = tracer
          example.run
          Thread.current[:_buildkite_tracer] = nil

          tracer.finalize

          trace = RSpec::Buildkite::Insights::Uploader::Trace.new(example, tracer.history)
          RSpec::Buildkite::Insights.uploader.traces << trace
        end

        config.after(:suite) do
          # This needs the lonely operater as the session will be nil
          # if auth against the API token fails
          RSpec::Buildkite::Insights.session&.close
        end
      end

      RSpec::Buildkite::Insights::Network.configure
      RSpec::Buildkite::Insights::Object.configure

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
      end
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end
  end
end
