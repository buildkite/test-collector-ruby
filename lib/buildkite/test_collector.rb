# frozen_string_literal: true

module Buildkite
  module TestCollector
  end
end

require "json"
require "logger"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "tmpdir"

require_relative "test_collector/version"
require_relative "test_collector/error"
require_relative "test_collector/ci"
require_relative "test_collector/http_client"
require_relative "test_collector/uploader"
require_relative "test_collector/network"
require_relative "test_collector/object"
require_relative "test_collector/trace"
require_relative "test_collector/tracer"
require_relative "test_collector/session"
require_relative "test_collector/uuid"
require_relative "test_collector/otel"

module Buildkite
  module TestCollector
    DEFAULT_URL = "https://analytics-api.buildkite.com/v1/uploads"
    DEFAULT_UPLOAD_BATCH_SIZE = 500
    class << self
      attr_accessor :api_token
      attr_accessor :url
      attr_accessor :uploader
      attr_accessor :session
      attr_accessor :tracing_enabled
      attr_accessor :artifact_path
      attr_accessor :location_prefix
      attr_accessor :test_runner
      attr_accessor :env
      attr_accessor :tags
      attr_accessor :batch_size
      attr_accessor :trace_min_duration
      attr_accessor :span_filters
    end

    def self.configure(hook:, token: nil, url: nil, tracing_enabled: true, artifact_path: nil, location_prefix: nil, env: {}, tags: {}, otel_enabled: false, otel_instrumentations: nil)
      self.api_token = (token || ENV["BUILDKITE_ANALYTICS_TOKEN"])&.strip
      self.url = url || ENV["BUILDKITE_ANALYTICS_ENDPOINT"] || DEFAULT_URL
      self.tracing_enabled = tracing_enabled
      self.artifact_path = artifact_path
      self.location_prefix = location_prefix || ENV["BUILDKITE_ANALYTICS_LOCATION_PREFIX"]
      self.test_runner = hook.to_s
      self.env = env
      self.tags = default_tags.merge(tags)
      self.batch_size = ENV.fetch("BUILDKITE_ANALYTICS_UPLOAD_BATCH_SIZE") { DEFAULT_UPLOAD_BATCH_SIZE }.to_i

      trace_min_ms_string = ENV["BUILDKITE_ANALYTICS_TRACE_MIN_MS"]
      self.trace_min_duration = if trace_min_ms_string && !trace_min_ms_string.empty?
        Float(trace_min_ms_string) / 1000
      end

      self.span_filters = []
      unless self.trace_min_duration.nil?
        self.span_filters << MinDurationSpanFilter.new(self.trace_min_duration)
      end

      # Defer OTel setup until RSpec's before(:suite), after application and support files have loaded.
      @otel_options = nil
      if otel_enabled && test_runner == "rspec"
        @otel_options = {
          # Undocumented, for development purposes.
          endpoint: ENV["BUILDKITE_ANALYTICS_OTLP_ENDPOINT"] || Buildkite::TestCollector::OTel::DEFAULT_ENDPOINT,
          api_token: api_token,
          run_env: Buildkite::TestCollector::CI.env,
          instrumentations: otel_instrumentations,
        }
      end
      self.hook_into(hook)
    end

    def self.start_otel
      options = @otel_options
      @otel_options = nil
      Buildkite::TestCollector::OTel.configure!(**options) if options
    end

    def self.hook_into(hook)
      file = "test_collector/library_hooks/#{hook}"
      require_relative file
    rescue LoadError
      raise ArgumentError.new("#{hook.inspect} is not a supported Buildkite Analytics Test library hook.")
    end

    # Tags every execution in the upload with the ID of the agent running it,
    # so failures can be grouped by runner. Omitted when the agent doesn't
    # expose an ID (e.g. outside Buildkite), so callers can still supply their
    # own "ci.runner.id" tag without it being clobbered.
    def self.default_tags
      agent_id = ENV["BUILDKITE_AGENT_ID"]
      return {} if agent_id.nil? || agent_id.strip.empty?

      { "ci.runner.id" => agent_id }
    end
    private_class_method :default_tags

    def self.annotate(content)
      tracer = Buildkite::TestCollector::Uploader.tracer
      tracer&.enter("annotation", **{ content: content })
      tracer&.leave
    end

    # Set a key=value tag on the current test execution.
    def self.tag_execution(key, value)
      tags = Thread.current[:_buildkite_tags]
      raise "_buildkite_tags not available" unless tags

      unless key.is_a?(String) && value.is_a?(String)
        raise ArgumentError, "tag key and value expected string"
      end

      tags[key] = value
    end

    def self.enable_tracing!
      return unless self.tracing_enabled

      Buildkite::TestCollector::Network.configure
      Buildkite::TestCollector::Object.configure

      return unless defined?(ActiveSupport)

      require "active_support/notifications"

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        Buildkite::TestCollector::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
      end
    end

    class MinDurationSpanFilter
      def initialize(min_duration)
        @min_duration = min_duration
      end

      def call(span)
        span.duration > @min_duration
      end
    end
  end
end
