# frozen_string_literal: true

require_relative "insights/version"

module RSpec::Buildkite::Insights
  class Error < StandardError; end

  def self.configure
    require_relative "insights/uploader"

    self::Uploader.configure
  end
end
