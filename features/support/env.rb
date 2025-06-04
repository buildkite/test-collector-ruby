require 'buildkite/test_collector'
Buildkite::TestCollector.configure(
  hook: :cucumber, url: "http://analytics-api.buildkite.localhost/v1/uploads"
)
