# frozen_string_literal: true

require "timeout"
require "tmpdir"

require_relative "collector/version"
require_relative "collector/logger"

module Buildkite
  module Collector
    class Error < StandardError; end
    class TimeoutError < ::Timeout::Error; end

    DEFAULT_URL = "https://analytics-api.buildkite.com/v1/uploads"

    class << self
      attr_accessor :api_token
      attr_accessor :url
      attr_accessor :uploader
      attr_accessor :session
      attr_accessor :debug_enabled
      attr_accessor :debug_filepath
    end

    def self.configure(token: nil, url: nil, debug_enabled: false, debug_filepath: nil, hook: :rspec)
      self.api_token = token || ENV["BUILDKITE_ANALYTICS_TOKEN"]
      self.url = url || DEFAULT_URL
      self.debug_enabled = debug_enabled || !!(ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"])
      self.debug_filepath = debug_filepath || ENV["BUILDKITE_ANALYTICS_DEBUG_FILEPATH"] || Dir.tmpdir

      self.hook_into(hook)
    end

    def self.hook_into(hook)
      file = "collector/library_hooks/#{hook}"
      require_relative file
    rescue LoadError => e
      raise ArgumentError.new("#{hook.inspect} is not a supported Buildkite Analytics Test library hook.")
    end

    def self.annotate(content)
      tracer = Buildkite::Collector::Uploader.tracer
      tracer&.enter("annotation", **{ content: content })
      tracer&.leave
    end

    def self.log_formatter
      @log_formatter ||= Buildkite::Collector::Logger::Formatter.new
    end

    def self.log_formatter=(log_formatter)
      @log_formatter = log_formatter
      logger.formatter = log_formatter
    end

    def self.logger=(logger)
      @logger = logger
    end

    def self.logger
      return @logger if defined?(@logger)

      debug_mode = ENV.fetch("BUILDKITE_ANALYTICS_DEBUG_ENABLED") do
        $DEBUG
      end

      level = !!debug_mode ? ::Logger::DEBUG : ::Logger::WARN
      @logger ||= Buildkite::Collector::Logger.new($stderr, level: level)
    end
  end
end
