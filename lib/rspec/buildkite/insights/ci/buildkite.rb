# frozen_string_literal: true

module RSpec::Buildkite::Insights::CI
  class Buildkite
    NAME = "buildkite"

    def self.env
      {
        "CI" => NAME,
        "key" => ENV["BUILDKITE_BUILD_ID"],
        "url" => ENV["BUILDKITE_BUILD_URL"],
        "branch" => ENV["BUILDKITE_BRANCH"],
        "commit_sha" => ENV["BUILDKITE_COMMIT"],
      }
    end
  end
end
