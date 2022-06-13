# frozen_string_literal: true

require "buildkite/test_collector/rspec_plugin/trace"

RSpec.describe Buildkite::TestCollector::RSpecPlugin::Trace do
  subject(:trace) { Buildkite::TestCollector::RSpecPlugin::Trace.new(example, history: history) }
  let(:example) { double(id: "test for invalid character '\xC8'").as_null_object }
  let(:history) do
    {
      children: [
        {
          start_at: 347611.734956,
          detail: %{"query"=>"SELECT '\xC8'"}
        }
      ]
    }
  end

  context "Location from Trace" do
    before do
      allow(example).to receive(:location) { "/Users/hello/path/to/your_test.rb" }
    end

    it "returns location from test" do
      prefix = trace.as_hash[:location_prefix]
      result = trace.as_hash[:location]

      expect(prefix).to be_nil
      expect(result).to eq "/Users/hello/path/to/your_test.rb"
    end

    it "adds custom location prefix via ENV" do
      env = ENV["BUILDKITE_ANALYTICS_LOCATION_PREFIX"]
      ENV["BUILDKITE_ANALYTICS_LOCATION_PREFIX"] = "payments"

      prefix = trace.as_hash[:location_prefix]
      result = trace.as_hash[:location]

      expect(prefix).to eq "payments"
      expect(result).to eq "payments/Users/hello/path/to/your_test.rb"

      ENV["BUILDKITE_ANALYTICS_LOCATION_PREFIX"] = env
    end
  end

  describe '#as_hash' do
    it 'removes invalid UTF-8 characters from top level values' do
      identifier = trace.as_hash[:identifier]

      expect(identifier).to include('test for invalid character')
      expect(identifier).to be_valid_encoding
    end

    it 'removes invalid UTF-8 characters from nested values' do
      history_json = trace.as_hash[:history].to_json

      expect(history_json).to include('query')
      expect(history_json).to be_valid_encoding
    end

    it 'does not alter data types which are not strings' do
      history_json = trace.as_hash[:history].to_json

      expect(history_json).to include('347611.734956')
    end
  end
end
