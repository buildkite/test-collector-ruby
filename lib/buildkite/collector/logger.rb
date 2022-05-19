require "logger"
require "time"

module Buildkite::Collector
  class CustomFormatter < ::Logger::Formatter
    def call(severity, time, _program, message)
      "#{time.utc.iso8601(9)} pid=#{::Process.pid} tid=#{::Thread.current.object_id} #{severity}: #{message}\n"
    end
  end

  class CustomLogger < ::Logger
    def initialize(*args, **kwargs)
      super
      self.formatter = Buildkite::Collector.log_formatter
    end
  end

  def self.log_formatter
    @log_formatter ||= CustomFormatter.new
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
    @logger ||= CustomLogger.new($stderr, level)
  end
end
