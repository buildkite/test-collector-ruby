# frozen_string_literal: true

module RSpec::Buildkite::Insights::CI
  class GitHubActions
    NAME = "github_actions"

    def self.env
      key = ENV["GITHUB_ACTION"] + "-" + ENV["GITHUB_RUN_ID"] + "-" + ENV["GITHUB_RUN_NUMBER"]
      url = File.join("https://github.com", ENV["GITHUB_REPOSITORY"], "actions/runs", ENV["GITHUB_RUN_ID"])

      {
        "CI" => NAME,
        "key" => key,
        "url" => url,
        "branch" => ENV["GITHUB_REF"], # could be nil
        "commit_sha" => ENV["GITHUB_SHA"],
      }
    end
  end
end
