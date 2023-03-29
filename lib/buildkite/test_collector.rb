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
require "securerandom"
require "socket"
require "websocket"

require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/notifications"

require_relative "test_collector/version"
require_relative "test_collector/error"
require_relative "test_collector/ci"
require_relative "test_collector/http_client"
require_relative "test_collector/uploader"
require_relative "test_collector/network"
require_relative "test_collector/object"
require_relative "test_collector/tracer"
require_relative "test_collector/session"

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
      attr_accessor :batch_size
    end

    def self.configure(hook:, token: nil, url: nil, tracing_enabled: true, artifact_path: nil, env: {})
      self.api_token = (token || ENV["BUILDKITE_ANALYTICS_TOKEN"])&.strip
      self.url = url || DEFAULT_URL
      self.tracing_enabled = tracing_enabled
      self.artifact_path = artifact_path
      self.env = env
      self.batch_size = ENV.fetch("BUILDKITE_ANALYTICS_UPLOAD_BATCH_SIZE") { DEFAULT_UPLOAD_BATCH_SIZE }.to_i
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

    def self.enable_tracing!
      return unless self.tracing_enabled

      Buildkite::TestCollector::Network.configure
      Buildkite::TestCollector::Object.configure

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        Buildkite::TestCollector::Uploader.tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
      end
    end
  end
end
