# frozen_string_literal: true

require "securerandom"

module RSpec::Buildkite::Analytics::CI
  def self.env
    puts "⭐️"*50
    puts %(BUILDKITE: #{ENV["BUILDKITE"]})
    puts %(BUILDKITE_BUILD_ID: #{ENV["BUILDKITE_BUILD_ID"]})
    puts %(BUILDKITE_BUILD_URL: #{ENV["BUILDKITE_BUILD_URL"]})
    puts %(BUILDKITE_BRANCH: #{ENV["BUILDKITE_BRANCH"]})
    puts %(BUILDKITE_COMMIT: #{ENV["BUILDKITE_COMMIT"]})
    puts %(BUILDKITE_BUILD_NUMBER: #{ENV["BUILDKITE_BUILD_NUMBER"]})
    puts %(BUILDKITE_JOB_ID: #{ENV["BUILDKITE_JOB_ID"]})
    puts %(BUILDKITE_MESSAGE: #{ENV["BUILDKITE_MESSAGE"]})
    puts "⭐️"*50

    if ENV["BUILDKITE"]
      {
        "CI" => "buildkite",
        "key" => ENV["BUILDKITE_BUILD_ID"],
        "url" => ENV["BUILDKITE_BUILD_URL"],
        "branch" => ENV["BUILDKITE_BRANCH"],
        "commit_sha" => ENV["BUILDKITE_COMMIT"],
        "number" => ENV["BUILDKITE_BUILD_NUMBER"],
        "job_id" => ENV["BUILDKITE_JOB_ID"],
        "message" => ENV["BUILDKITE_MESSAGE"]
      }
    else
      {
        "CI" => nil,
        "key" => SecureRandom.uuid
      }
    end
  end
end
