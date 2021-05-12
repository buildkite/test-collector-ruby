# frozen_string_literal: true

module RSpec::Buildkite::Insights::CI
  class GitHubActions
    def self.key
      File.join(
        "https://github.com",
        ENV["GITHUB_REPOSITORY"],
        "actions/runs",
        ENV["GITHUB_RUN_ID"]
      )
    end
  end
end
