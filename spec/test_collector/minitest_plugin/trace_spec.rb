# frozen_string_literal: true

require "buildkite/test_collector/minitest_plugin/trace"

RSpec.describe Buildkite::TestCollector::MinitestPlugin::Trace do
  subject(:trace) { Buildkite::TestCollector::MinitestPlugin::Trace.new(result, history: history) }
  let(:result) { double("Result", name: "test_it_passes", test_it_passes: nil, result_code: 'F', failure: failure, failures: [failure]) }
  let(:failure) { double("Failure", message: message, backtrace: backtrace)}
  let(:message) { "test for invalid character'\xC8'\n    Expected: true\n    Actual: false" }
  let(:backtrace) { [
    '# ./lib/test/test.rb:5:in',
    '# ./lib/test/test.rb:15:in',
    '# ./lib/test/test.rb:16:in',
  ]}

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

    it 'sets the failure_expanded' do
      failure_expanded = trace.as_hash[:failure_expanded]
      expect(failure_expanded).not_to be_empty
      expect(failure_expanded[0][:expanded]).not_to include('test for invalid character')
    end

    it "sets the filename, when not in Rails" do
      expect(trace.as_hash[:file_name].split("/").last).to eq("method_double.rb")
    end

    let(:rails) { double("Rails", root: Pathname.new("./")) }
    it "sets the filename, when in Rails" do
      Rails = rails
      expect(trace.as_hash[:file_name].split("/").last).to eq("method_double.rb")
    end
  end
end
