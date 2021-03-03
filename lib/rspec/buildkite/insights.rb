# frozen_string_literal: true

require_relative "insights/version"

module RSpec::Buildkite::Insights
  class Error < StandardError; end

  DEFAULT_URL = "https://insights-api.buildkite.com/v1/upload"

  class << self
    attr_accessor :api_token
    attr_accessor :filename
    attr_accessor :url
  end

  def self.configure(token: nil, url: nil, filename: nil)
    self.api_token = token || ENV["BUILDKITE_INSIGHTS_TOKEN"]
    self.url = url || DEFAULT_URL
    self.filename = filename

    require_relative "insights/uploader"

    self::Uploader.configure
  end
end
