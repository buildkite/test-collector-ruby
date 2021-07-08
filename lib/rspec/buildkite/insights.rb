# frozen_string_literal: true

require "timeout"

require_relative "insights/version"

module RSpec::Buildkite::Insights
  class Error < StandardError; end
  class TimeoutError < ::Timeout::Error; end

  DEFAULT_URL = "https://insights-api.buildkite.com/v1/uploads"

  class << self
    attr_accessor :api_token
    attr_accessor :filename
    attr_accessor :url
    attr_accessor :uploader
    attr_accessor :session
    attr_accessor :connection_timeout
  end

  def self.configure(token: nil, url: nil, filename: nil, connection_timeout: nil)
    self.api_token = token || ENV["BUILDKITE_INSIGHTS_TOKEN"]
    self.url = url || DEFAULT_URL
    self.filename = filename
    self.connection_timeout = connection_timeout || 30

    require_relative "insights/uploader"

    self::Uploader.configure
  end
end
