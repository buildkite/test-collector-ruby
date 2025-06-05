require 'buildkite/test_collector'
Buildkite::TestCollector.configure(
  hook: :cucumber, url: "https://analytics-api.buildkite.com/v1/uploads"
)
