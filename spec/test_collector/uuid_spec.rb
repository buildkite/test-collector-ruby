# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::UUID do
  describe '.call' do
    it 'returns a UUID' do
      expect(described_class.call).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  describe '.v7' do
    it 'returns a UUID' do
      expect(described_class.v7).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'returns a different value on each call' do
      expect(described_class.v7).not_to eq(described_class.v7)
    end
  end
end
