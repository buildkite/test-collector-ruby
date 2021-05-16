# frozen_string_literal: true

module RSpec::Buildkite::Insights::CI
  class CircleCI
    NAME = "circleci"

    def self.env
      number = ENV["CIRCLE_BUILD_NUM"]
      key = ENV["CIRCLE_WORKFLOW_ID"] + "-" + number

      {
        "CI" => NAME,
        "key" => key,
        "url" => ENV["CIRCLE_BUILD_URL"],
        "branch" => ENV["CIRCLE_BRANCH"],
        "commit_sha" => ENV["CIRCLE_SHA1"],
        "number" => number,
      }
    end
  end
end
