# frozen_string_literal: true

module RSpec::Buildkite::Insights::CI
  class CircleCI
    def self.key
      ENV["CIRCLE_BUILD_URL"]
    end
  end
end
