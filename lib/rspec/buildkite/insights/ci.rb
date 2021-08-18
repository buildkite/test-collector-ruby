# frozen_string_literal: true

require "securerandom"

module RSpec::Buildkite::Insights::CI
  def self.env
    {
      "CI" => "buildkite",
      "key" => ENV["BUILDKITE_BUILD_ID"] || SecureRandom.uuid,
      "url" => ENV["BUILDKITE_BUILD_URL"],
      "branch" => ENV["BUILDKITE_BRANCH"],
      "commit_sha" => ENV["BUILDKITE_COMMIT"],
      "number" => ENV["BUILDKITE_BUILD_NUMBER"],
      "job_id" => ENV["BUILDKITE_JOB_ID"]
    }
  end
end
