# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require "net/http"
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

module RSpec::Buildkite::Analytics
  class Uploader
    class Trace
      attr_accessor :example, :failure_reason, :failure_expanded
      attr_reader :id, :history

      def initialize(example, history)
        @id = SecureRandom.uuid
        @example = example
        @history = history
        @failure_reason = nil
        @failure_expanded = []
      end

      def result_state
        case example.execution_result.status
        when :passed; "passed"
        when :failed; "failed"
        when :pending; "skipped"
        end
      end

      def as_hash
        {
          id: @id,
          scope: example.example_group.metadata[:full_description],
          name: example.description,
          identifier: example.id,
          location: example.location,
          file_name: generate_file_name(example),
          result: result_state,
          failure_reason: failure_reason,
          failure_expanded: failure_expanded,
          history: history,
        }.with_indifferent_access.compact
      end

      private

      def generate_file_name(example)
        file_path_regex = /^(.*?\.(rb|feature))/
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
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end
  end
end
