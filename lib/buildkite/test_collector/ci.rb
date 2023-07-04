# frozen_string_literal: true

class Buildkite::TestCollector::CI
  def self.env
    new.env
  end

  # The analytics env are more specific than the automatic ci platform env.
  # If they've been specified we'll assume the user wants to use that value instead.
  def env
    ci_env.merge(analytics_env).merge(Buildkite::TestCollector.env)
  end

  private

  def ci_env
    return buildkite if ENV["BUILDKITE_BUILD_ID"]
    return github_actions if ENV["GITHUB_RUN_NUMBER"]
    return circleci if ENV["CIRCLE_WORKFLOW_ID"]
    return generic if ENV["CI"]

    {
      "CI" => nil,
      "key" => Buildkite::TestCollector::UUID.call,
    }
  end

  def analytics_env
    {
      "key" => ENV["BUILDKITE_ANALYTICS_KEY"],
      "url" => ENV["BUILDKITE_ANALYTICS_URL"],
      "branch" => ENV["BUILDKITE_ANALYTICS_BRANCH"],
      "commit_sha" => ENV["BUILDKITE_ANALYTICS_SHA"],
      "job_id" => ENV["BUILDKITE_ANALYTICS_JOB_ID"],
      "message" => ENV["BUILDKITE_ANALYTICS_MESSAGE"],
      "execution_name_prefix" => ENV["BUILDKITE_ANALYTICS_EXECUTION_NAME_PREFIX"],
      "execution_name_suffix" => ENV["BUILDKITE_ANALYTICS_EXECUTION_NAME_SUFFIX"],
      "version" => Buildkite::TestCollector::VERSION,
      "collector" => "ruby-#{Buildkite::TestCollector::NAME}",
      "number" => ENV["BUILDKITE_ANALYTICS_NUMBER"],
      "build_id" => ENV["BUILDKITE_ANALYTICS_BUILD_ID"]
    }.compact
  end

  def generic
    {
      "CI" => "generic",
      "key" => Buildkite::TestCollector::UUID.call,
    }
  end

  def buildkite
    {
      "CI" => "buildkite",
      "key" => ENV["BUILDKITE_BUILD_ID"],
      "url" => ENV["BUILDKITE_BUILD_URL"],
      "branch" => ENV["BUILDKITE_BRANCH"],
      "commit_sha" => ENV["BUILDKITE_COMMIT"],
      "job_id" => ENV["BUILDKITE_JOB_ID"],
      "message" => ENV["BUILDKITE_MESSAGE"],
      "number" => ENV["BUILDKITE_BUILD_NUMBER"],
      "build_id" => ENV["BUILDKITE_BUILD_ID"]
    }
  end

  def github_actions
    {
      "CI" => "github_actions",
      "key" => "#{ENV["GITHUB_ACTION"]}-#{ENV["GITHUB_RUN_NUMBER"]}-#{ENV["GITHUB_RUN_ATTEMPT"]}",
      "url" => File.join("https://github.com", ENV["GITHUB_REPOSITORY"], "actions/runs", ENV["GITHUB_RUN_ID"]),
      "branch" => ENV["GITHUB_REF_NAME"],
      "commit_sha" => ENV["GITHUB_SHA"],
      "number" => ENV["GITHUB_RUN_NUMBER"],
      "build_id" => "#{ENV["GITHUB_RUN_ID"]}-#{ENV["GITHUB_RUN_ATTEMPT"]}"
    }
  end

  def circleci
    {
      "CI" => "circleci",
      "key" => ENV["CIRCLE_WORKFLOW_ID"],
      "url" => ENV["CIRCLE_BUILD_URL"],
      "branch" => ENV["CIRCLE_BRANCH"],
      "commit_sha" => ENV["CIRCLE_SHA1"],
      "number" => ENV["CIRCLE_WORKFLOW_ID"], # There is no human readable ENV in CircleCi
      "build_id" => ENV["CIRCLE_WORKFLOW_ID"] # Retries in CircleCi generate a new workflow id each time
    }
  end
end
