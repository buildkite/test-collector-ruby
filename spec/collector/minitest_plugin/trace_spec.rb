# frozen_string_literal: true

require "buildkite/collector/minitest_plugin/trace"

RSpec.describe Buildkite::Collector::MinitestPlugin::Trace do
  subject(:trace) { Buildkite::Collector::MinitestPlugin::Trace.new(result, history: history) }
  let(:result) { double("Result", name: "test_it_passes", test_it_passes: nil, result_code: 'F', failure: failure) }
  let(:failure) { double("Failure", message: "test for invalid character '\xC8'")}
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

  describe '#as_hash' do
    it 'removes invalid UTF-8 characters from top level values' do
      failure_reason = trace.as_hash[:failure_reason]

      expect(failure_reason).to include('test for invalid character')
      expect(failure_reason).to be_valid_encoding
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
