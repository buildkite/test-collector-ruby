# frozen_string_literal: true

module RSpec::Buildkite::Insights::CI
  class Buildkite
    def self.key
      ENV["BUILDKITE_BUILD_URL"]
    end
  end
end
