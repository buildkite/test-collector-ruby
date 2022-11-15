# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector do
  context "RSpec" do
    let(:hook) { :rspec }

    it "can configure api_token and url" do
      analytics = Buildkite::TestCollector
      ENV["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      analytics.configure(hook: hook)

      expect(analytics.api_token).to eq "MyToken"
      expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
    end

    it "can configure custom env" do
      analytics = Buildkite::TestCollector
      env = { test: "test value" }

      analytics.configure(hook: hook, env: env)

      expect(analytics.env).to match env
    end
  end

  context "Minitest" do
    let(:hook) { :minitest }

    it "can configure api_token and url" do
      analytics = Buildkite::TestCollector
      ENV["BUILDKITE_ANALYTICS_TOKEN"] = "MyToken"

      analytics.configure(hook: hook)

      expect(analytics.api_token).to eq "MyToken"
      expect(analytics.url).to eq "https://analytics-api.buildkite.com/v1/uploads"
    end

    it "can configure custom env" do
      analytics = Buildkite::TestCollector
      env = { test: "test value" }

      analytics.configure(hook: hook, env: env)

      expect(analytics.env).to match env
    end
  end

  describe ".safe" do
    let(:logger) { TestLogger.new }

    class TestLogger
      attr_reader :errors

      def initialize
        @errors = []
      end

      def error(message)
        @errors << message
      end
    end

    before { Buildkite::TestCollector.logger = logger }

    it "suppresses exceptions and logs them to logger.error" do
      expect{ described_class.safe { raise "penguines dance" } }.to_not raise_error
      expect(logger.errors.first).to eq("Buildkite::TestCollector received exception: penguines dance")
    end
  end
end
