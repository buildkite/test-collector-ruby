# frozen_string_literal: true

RSpec.describe RSpec::Buildkite::Insights do
  it "DEFAULT_URL returns the url of Insights endpoint" do
    expect(RSpec::Buildkite::Insights::DEFAULT_URL).to eq "https://insights-api.buildkite.com/v1/uploads"
  end
end
