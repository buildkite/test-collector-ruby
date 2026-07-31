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
      "number" => ENV["BUILDKITE_ANALYTICS_NUMBER"],
      "job_id" => ENV["BUILDKITE_ANALYTICS_JOB_ID"],
      "message" => ENV["BUILDKITE_ANALYTICS_MESSAGE"],
      "execution_name_prefix" => ENV["BUILDKITE_ANALYTICS_EXECUTION_NAME_PREFIX"],
      "execution_name_suffix" => ENV["BUILDKITE_ANALYTICS_EXECUTION_NAME_SUFFIX"],
      "language_version" => RUBY_VERSION,
      "version" => Buildkite::TestCollector::VERSION,
      "collector" => "ruby-#{Buildkite::TestCollector::NAME}",
      "location_prefix" => Buildkite::TestCollector.location_prefix,
      "test_runner" => Buildkite::TestCollector.test_runner,
      "trace_min_duration" => Buildkite::TestCollector.trace_min_duration&.to_s,
    }.select { |_, value| !value.nil? }
  end

  def buildkite
    {
      "CI" => "buildkite",
      "key" => ENV["BUILDKITE_BUILD_ID"],
      "url" => ENV["BUILDKITE_BUILD_URL"],
      "branch" => ENV["BUILDKITE_BRANCH"],
      "commit_sha" => ENV["BUILDKITE_COMMIT"],
      "number" => ENV["BUILDKITE_BUILD_NUMBER"],
      "job_id" => ENV["BUILDKITE_JOB_ID"],
      "message" => ENV["BUILDKITE_MESSAGE"],
    }
  end
end
