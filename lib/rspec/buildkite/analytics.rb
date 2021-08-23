# frozen_string_literal: true

require "timeout"

require_relative "analytics/version"

module RSpec::Buildkite::Analytics
  class Error < StandardError; end
  class TimeoutError < ::Timeout::Error; end

  DEFAULT_URL = "https://analytics-api.buildkite.com/v1/uploads"

  class << self
    attr_accessor :api_token
    attr_accessor :filename
    attr_accessor :url
    attr_accessor :uploader
    attr_accessor :session
  end

  def self.configure(token: nil, url: nil, filename: nil)
    self.api_token = token || ENV["BUILDKITE_ANALYTICS_TOKEN"]
    self.url = url || DEFAULT_URL
    self.filename = filename

    require_relative "analytics/uploader"

    self::Uploader.configure
  end
end
