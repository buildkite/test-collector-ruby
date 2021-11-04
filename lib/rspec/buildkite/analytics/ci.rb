# frozen_string_literal: true

require "securerandom"

module RSpec::Buildkite::Analytics::CI
  def self.env
    if ENV["BUILDKITE_BUILD_ID"]
      {
        "CI" => "buildkite",
        "key" => ENV["BUILDKITE_BUILD_ID"],
        "url" => ENV["BUILDKITE_BUILD_URL"],
        "branch" => ENV["BUILDKITE_BRANCH"],
        "commit_sha" => ENV["BUILDKITE_COMMIT"],
        "number" => ENV["BUILDKITE_BUILD_NUMBER"],
        "job_id" => ENV["BUILDKITE_JOB_ID"],
        "message" => ENV["BUILDKITE_MESSAGE"],
        "debug" => ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"]
      }
    else
      {
        "CI" => nil,
        "key" => SecureRandom.uuid,
        "debug" => ENV["BUILDKITE_ANALYTICS_DEBUG_ENABLED"]
      }
    end
  end
end
