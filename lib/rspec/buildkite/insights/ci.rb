# frozen_string_literal: true

require "securerandom"

require_relative "ci/buildkite"
require_relative "ci/circleci"
require_relative "ci/github_actions"

module RSpec::Buildkite::Insights::CI
  class NoCI
    def self.key
      SecureRandom.uuid
    end
  end

  def self.key
    provider_class = case
      when ENV["BUILDKITE"]
        Buildkite
      when ENV["CIRCLECI"]
        CircleCI
      when ENV["GITHUB_ACTIONS"]
        GitHubActions
      else
        NoCI
      end

    provider_class.key
  end
end
