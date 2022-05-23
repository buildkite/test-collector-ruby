# frozen_string_literal: true

require "logger"
require "buildkite/collector/logger"

RSpec.describe "Logger" do
  describe ".logger" do
    let(:logger) { Buildkite::Collector }

    it "accepts standard logger arguments" do
      logger = Buildkite::Collector::Logger.new("/dev/null", level: Logger::INFO)

      expect(logger.level).to eq ::Logger::INFO
    end

    it "level respects BUILDKITE_ANALYTICS_DEBUG_ENABLED" do
      env = ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"]
      ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"] = "true"

      result = Buildkite::Collector.logger.level

      expect(result).to eq ::Logger::DEBUG

      ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"] = env
    end

    it "level respects $DEBUG" do
      debug = $DEBUG
      $DEBUG = true

      result = Buildkite::Collector.logger.level

      expect(result).to eq ::Logger::DEBUG

      $DEBUG = debug
    end

    it "returns our logger by default" do
      result = Buildkite::Collector.logger

      expect(result).to be_a(Buildkite::Collector::Logger)
    end

    it "returns our formatter by default" do
      result = Buildkite::Collector.log_formatter

      expect(result).to be_a(Buildkite::Collector::Logger::Formatter)
    end

    it "can change logger" do
      logger = ::Logger.new("/dev/null")
      Buildkite::Collector.logger = logger

      result = Buildkite::Collector.logger

      expect(result).to eq logger
    end

    it "can change formatter" do
      formatter = Logger::Formatter.new
      Buildkite::Collector.log_formatter = formatter

      result = Buildkite::Collector.log_formatter

      expect(result).to eq formatter
    end

    def reset_io(io)
      io.truncate(0)
      io.rewind
    end

    it "formatted output contains ISO 8601 timstamp, process and thread id" do
      # Replace IO for testing
      io = StringIO.new
      logger = Buildkite::Collector::Logger.new(io)
      logger.formatter = Buildkite::Collector::Logger::Formatter.new
      Buildkite::Collector.logger = logger

      Buildkite::Collector.logger.info "TestAnalytics-123"

      result = io.string

      expect(result).to match /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.\d{6,}Z/
      expect(result).to match /pid=\d{1,}/
      expect(result).to match /tid=\d{1,}/
      expect(result).to match /TestAnalytics-123/

      reset_io(io)
    end
  end
end
