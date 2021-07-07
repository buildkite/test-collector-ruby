# frozen_string_literal: true

require "logger"

module RSpec::Buildkite::Insights
  class Debugger
    class NullLogger
      def debug(message)
      end
    end

    Logger = begin
      if RSpec::Buildkite::Insights.debug
        logger = ::Logger.new($stderr)
        logger.level = ::Logger::DEBUG
        logger
      else
        NullLogger.new
      end
    end.freeze

    def self.debug(message, logger: Logger)
      logger.debug(message)
    end
  end
end
