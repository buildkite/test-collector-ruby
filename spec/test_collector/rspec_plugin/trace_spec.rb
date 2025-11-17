# frozen_string_literal: true

require "buildkite/test_collector/rspec_plugin/trace"

RSpec.describe Buildkite::TestCollector::RSpecPlugin::Trace do
  subject(:trace) do
    Buildkite::TestCollector::RSpecPlugin::Trace.new(
      example,
      history: history,
      tags: tags,
      location_prefix: location_prefix,
    )
  end

  let(:example) { double(id: "test for invalid character '\xC8'").as_null_object }
  let(:location_prefix) { nil }

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

  let(:tags) { nil }

  describe '#as_hash' do
    describe "file_name" do
      let(:example) { fake_example(file_path: file_path) }
      let(:file_path) { "./spec/foo_spec.rb" }

      it "is set from example.file_path" do
        expect(trace.as_hash).to include(
          file_name: "./spec/foo_spec.rb",
          location: "./spec/foo_spec.rb:42",
        )
      end

      context "when location_prefix is provided" do
        let(:location_prefix) { "some/prefix" }

        it "prepends location_prefix to example.file_path" do
          expect(trace.as_hash).to include(
            file_name: "some/prefix/spec/foo_spec.rb",
            location: "some/prefix/spec/foo_spec.rb:42",
          )
        end
      end
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

    context "with tags" do
      let(:tags) { { "hello" => "world" } }

      it "includes the tags" do
        expect(trace.as_hash[:tags]).to eq({ "hello" => "world" })
      end
    end
  end
end
