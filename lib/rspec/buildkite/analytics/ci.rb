# frozen_string_literal: true

require "securerandom"

module RSpec::Buildkite::Analytics::CI
  def self.env
    message = ENV["BUILDKITE_MESSAGE"]
    message = message.split(/(\n)|(\r\n)/).first if message

    env = {
      "CI" => ENV["BUILDKITE"] ? "buildkite" : nil,
      "key" => ENV["BUILDKITE_BUILD_ID"] || SecureRandom.uuid,
      "url" => ENV["BUILDKITE_BUILD_URL"],
      "branch" => ENV["BUILDKITE_BRANCH"],
      "commit_sha" => ENV["BUILDKITE_COMMIT"],
      "number" => ENV["BUILDKITE_BUILD_NUMBER"],
      "job_id" => ENV["BUILDKITE_JOB_ID"],
      "message" => message
    }
  end
end
