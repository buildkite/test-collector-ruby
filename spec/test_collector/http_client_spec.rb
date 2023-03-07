# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::HTTPClient do
  subject { described_class.new("buildkite.localhost") }

  let(:example_group) { OpenStruct.new(metadata: { full_description: "i love to eat pies" }) }
  let(:execution_result) { OpenStruct.new(status: :passed) }
  let(:example) do
    OpenStruct.new(
      example_group: example_group,
      description: "mince and cheese",
      id: "12",
      location: "123 Pie St",
      execution_result: execution_result
    )
  end

  let(:trace) { Buildkite::TestCollector::RSpecPlugin::Trace.new(example, history: "pie lore") }

  let(:http_double) { double("Net::HTTP_double") }
  let(:post_double) { double("Net::HTTP::Post") }

  let(:request_body) do
    {
      "run_env": {
        "CI": nil,
        "key": "build-123",
        "version": "2.0.0.pre",
        "collector": "ruby-buildkite-test_collector",
        "test": "test_value"
      },
      "format": "json",
      "data": [{
        "id": trace.id,
        "scope": "i love to eat pies",
        "name": "mince and cheese",
        "location": "123 Pie St",
        "result": "passed",
        "failure_expanded": [],
        "history": "pie lore"
      }]
    }
  end

  before do
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)

    allow(Net::HTTP::Post).to receive(:new).with("buildkite.localhost", {"Authorization"=>"Token token=\"my-cool-token\"", "Content-Type"=>"application/json"}).and_return(post_double)

    allow(ENV).to receive(:[]).and_call_original
    fake_env("BUILDKITE_ANALYTICS_KEY", "build-123")

    # these have to be reset or these tests will fail on CI
    fake_env("CI", nil)
    fake_env("BUILDKITE_BUILD_ID", nil)
    fake_env("GITHUB_RUN_NUMBER", nil)
    fake_env("CIRCLE_BUILD_NUM", nil)

    Buildkite::TestCollector.configure(hook: :rspec, token: "my-cool-token", env: { "test" => "test_value" })
  end

  describe "#post_json" do
    it "sends the right data" do
      expect(post_double).to receive(:body=).with(request_body.to_json)
      expect(http_double).to receive(:request).with(post_double)
      subject.post_json([trace])
    end
  end
end
