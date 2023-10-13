# frozen_string_literal: true

require "buildkite/test_collector/test_links_plugin/trace"

RSpec.describe Buildkite::TestCollector::TestLinksPlugin::Trace do
  let(:example_group) { OpenStruct.new(metadata: { full_description: 'i love to eat pies' }) }
  let(:execution_result) { OpenStruct.new(status: :failed) }
  let(:example) do
    OpenStruct.new(
      example_group: example_group,
      description: "test for invalid character '\xC8'",
      execution_result: execution_result
    )
  end
  subject(:trace) { Buildkite::TestCollector::TestLinksPlugin::Trace.new(example) }

  describe '#as_hash' do
    it 'removes invalid UTF-8 characters' do
      valid_name = trace.as_hash[:name]

      expect(valid_name.to_s).to eq("test for invalid character '�'")
      expect(valid_name.to_s).to be_valid_encoding
    end
  end
end
