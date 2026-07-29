# frozen_string_literal: true

require "buildkite/test_collector/rspec_plugin/trace"

RSpec.describe Buildkite::TestCollector::RSpecPlugin::Trace do
  subject(:trace) do
    Buildkite::TestCollector::RSpecPlugin::Trace.new(
      example,
      history: history,
      tags: tags,
      location_prefix: location_prefix,
      external_id: external_id,
    )
  end

  let(:example) { double(id: "test for invalid character '\xC8'").as_null_object }
  let(:location_prefix) { nil }
  let(:external_id) { nil }

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

      it "uses the same canonical path for OpenTelemetry" do
        expect(trace.otel_attributes).to include(
          "code.file.path" => "./spec/foo_spec.rb",
          "code.line.number" => 42,
        )
      end

      context "when location_prefix is provided for OpenTelemetry" do
        let(:location_prefix) { "some/prefix" }

        it "uses the prefixed execution path" do
          expect(trace.otel_attributes.fetch("code.file.path")).to eq("some/prefix/spec/foo_spec.rb")
        end
      end

      context "when the example comes from a shared example group" do
        let(:example) do
          fake_example(
            id: "./spec/consumer_spec.rb[1:1]",
            location: "./spec/support/shared_examples.rb:8",
            metadata: {
              shared_group_inclusion_backtrace: [
                OpenStruct.new(inclusion_location: "./spec/consumer_spec.rb:17"),
              ],
            },
          )
        end

        it "uses the shared example call site for the path and line" do
          expect(trace.otel_attributes).to include(
            "code.file.path" => "./spec/consumer_spec.rb",
            "code.line.number" => 17,
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

    context "with an external execution ID" do
      let(:external_id) { "019c8d97-f9ad-75a5-8173-dc6c1b54b901" }

      it "includes the external ID in the execution upload" do
        expect(trace.as_hash[:external_id]).to eq(external_id)
      end
    end
  end
end
