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
require_relative "test_collector/tracer"
require_relative "test_collector/session"
require_relative "test_collector/uuid"

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
      attr_accessor :env
      attr_accessor :tags
      attr_accessor :batch_size
      attr_accessor :trace_min_duration
      attr_accessor :span_filters
    end

    def self.configure(hook:, token: nil, url: nil, tracing_enabled: true, artifact_path: nil, env: {}, tags: {})
      if hook.to_sym == :cucumber && Gem::Version.new(RUBY_VERSION) < Gem::Version.new('2.7')
        raise UnsupportedFrameworkError.new("Cucumber is only supported in versions of Ruby >= 2.7")
      end

      self.api_token = (token || ENV["BUILDKITE_ANALYTICS_TOKEN"])&.strip
      self.url = url || DEFAULT_URL
      self.tracing_enabled = tracing_enabled
      self.artifact_path = artifact_path
      self.env = env
      self.tags = tags
      self.batch_size = ENV.fetch("BUILDKITE_ANALYTICS_UPLOAD_BATCH_SIZE") { DEFAULT_UPLOAD_BATCH_SIZE }.to_i

      trace_min_ms_string = ENV["BUILDKITE_ANALYTICS_TRACE_MIN_MS"]
      self.trace_min_duration = if trace_min_ms_string && !trace_min_ms_string.empty?
        Float(trace_min_ms_string) / 1000
      end

      self.span_filters = []
      unless self.trace_min_duration.nil?
        self.span_filters << MinDurationSpanFilter.new(self.trace_min_duration)
      end

      self.hook_into(hook)
    end

    def self.hook_into(hook)
      file = "test_collector/library_hooks/#{hook}"
      require_relative file
    rescue LoadError
      raise ArgumentError.new("#{hook.inspect} is not a supported Buildkite Analytics Test library hook.")
    end

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
