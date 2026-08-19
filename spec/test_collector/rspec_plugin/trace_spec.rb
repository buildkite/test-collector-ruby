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
      trace_id: trace_id,
    )
  end

  let(:example) { double(id: "test for invalid character '\xC8'").as_null_object }
  let(:location_prefix) { nil }
  let(:external_id) { nil }
  let(:trace_id) { nil }

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

    context "with an external ID" do
      let(:external_id) { "019c8d97-f9ad-75a5-8173-dc6c1b54b901" }

      it "includes the external ID" do
        expect(trace.as_hash[:external_id]).to eq(external_id)
      end
    end

    context "with an OpenTelemetry trace ID" do
      let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }

      it "includes the trace ID" do
        expect(trace.as_hash[:trace_id]).to eq(trace_id)
      end
    end

    it "omits the trace ID when OpenTelemetry is not enabled" do
      expect(trace.as_hash).not_to have_key(:trace_id)
    end
  end

  describe "#otel_attributes" do
    let(:example) { fake_example(file_path: "./spec/foo_spec.rb") }

    it "describes the test, using the same path as the upload" do
      expect(trace.otel_attributes).to eq(
        "test.case.name" => example.full_description,
        "test.suite.name" => example.example_group.metadata[:full_description],
        "code.file.path" => "./spec/foo_spec.rb",
        "code.line.number" => 42,
      )
    end

    context "with an external ID" do
      let(:external_id) { "019c8d97-f9ad-75a5-8173-dc6c1b54b901" }

      it "identifies the matching Test Engine execution" do
        expect(trace.otel_attributes.fetch("buildkite.test.execution.external_id"))
          .to eq(external_id)
      end
    end

    context "when location_prefix is provided" do
      let(:location_prefix) { "some/prefix" }

      it "uses the prefixed path, matching the upload" do
        expect(trace.otel_attributes.fetch("code.file.path")).to eq("some/prefix/spec/foo_spec.rb")
        expect(trace.otel_attributes.fetch("code.file.path")).to eq(trace.as_hash[:file_name])
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

      it "uses the shared example call site" do
        expect(trace.otel_attributes).to include(
          "code.file.path" => "./spec/consumer_spec.rb",
          "code.line.number" => 17,
        )
      end
    end
  end

  describe "#otel_attributes in OTLP-only mode" do
    subject(:trace) do
      Buildkite::TestCollector::RSpecPlugin::Trace.new(
        example,
        history: {},
        tags: tags,
        location_prefix: location_prefix,
        otel_only: true,
      )
    end

    let(:example) { fake_example(file_path: "./spec/foo_spec.rb", status: :passed) }
    let(:tags) { nil }

    it "carries the full execution details for server-side synthesis" do
      allow(example).to receive(:exception) { nil }

      expect(trace.otel_attributes).to eq(
        "execution.via" => "otlp",
        "test.scope" => "this is a fake example full description",
        "test.name" => "fake example name",
        "buildkite.test.location" => "./spec/foo_spec.rb:42",
        "buildkite.test.file_name" => "./spec/foo_spec.rb",
        "test.suite.name" => "this is a fake example full description",
        "test.case.name" => "this is a fake example full description",
        "code.file.path" => "./spec/foo_spec.rb",
        "code.line.number" => 42,
        "buildkite.test.result" => "passed",
      )
    end

    it "includes failure details as attributes" do
      allow(example).to receive(:exception) { StandardError.new("it broke") }
      trace.failure_reason = "it broke"
      trace.failure_expanded = [{ expanded: ["it broke"], backtrace: ["foo.rb:1"] }]

      expect(trace.otel_attributes).to include(
        "buildkite.test.result" => "failed",
        "buildkite.test.failure_reason" => "it broke",
        "buildkite.test.failure_expanded" =>
          %([{"expanded":["it broke"],"backtrace":["foo.rb:1"]}]),
      )
    end

    context "with execution tags" do
      let(:tags) { { "team" => "platform" } }

      it "includes them as span attributes" do
        allow(example).to receive(:exception) { nil }

        expect(trace.otel_attributes).to include("team" => "platform")
      end
    end

    context "when location_prefix is provided" do
      let(:location_prefix) { "some/prefix" }

      it "prefixes the file and location paths" do
        allow(example).to receive(:exception) { nil }

        expect(trace.otel_attributes).to include(
          "buildkite.test.file_name" => "some/prefix/spec/foo_spec.rb",
          "code.file.path" => "some/prefix/spec/foo_spec.rb",
          "buildkite.test.location" => "some/prefix/spec/foo_spec.rb:42",
        )
      end
    end
  end
end
