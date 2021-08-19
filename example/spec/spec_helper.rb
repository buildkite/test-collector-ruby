require "rspec"
require "rspec/buildkite/insights"

insights_token = "fake token"
insights_url = "http://insights.localhost/v1/uploads"

RSpec::Buildkite::Insights.configure(
  token: insights_token,
  url: insights_url,
)
