# frozen_string_literal: true

if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7')
  require "buildkite/test_collector/cucumber_plugin/trace"
  require "cucumber"

  RSpec.describe Buildkite::TestCollector::CucumberPlugin::Trace do
    subject(:trace) do
      Buildkite::TestCollector::CucumberPlugin::Trace.new(
        example,
        history: history,
        failure_reason: "This test failed",
        failure_expanded: "PICNIC: Problem in chair, not in computer"
      )
    end

    let(:example) do
      double(
        Cucumber::RunningTestCase::TestCase,
        name: "test_it_passes",
        location: 'spec/support/fixtures/features/a.feature',
        "passed?": false,
        "failed?": true,
      )
    end

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
else
  warn "Skipping #{__FILE__} — Cucumber support requires Ruby >= 2.7 (current: #{RUBY_VERSION})"
end
