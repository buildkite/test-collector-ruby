# frozen_string_literal: true

RSpec.describe Buildkite::Collector do
  context "RSpec" do
    it "can configure api_token and url" do
      analytics = Buildkite::Collector
      ENV["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      analytics.configure(hook: :rspec)

      expect(analytics.api_token).to eq "MyToken"
      expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
    end
  end

  context "Minitest" do
    it "can configure api_token and url" do
      analytics = Buildkite::Collector
      ENV["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      analytics.configure(hook: :minitest)

      expect(analytics.api_token).to eq "MyToken"
      expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
    end
  end
end
