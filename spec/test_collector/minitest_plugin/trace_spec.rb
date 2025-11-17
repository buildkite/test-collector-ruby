# frozen_string_literal: true

require "buildkite/test_collector/minitest_plugin/trace"
require "minitest"
require "pathname"

RSpec.describe Buildkite::TestCollector::MinitestPlugin::Trace do
  subject(:trace) do
    Buildkite::TestCollector::MinitestPlugin::Trace.new(
      example,
      history: history,
      tags: tags,
      location_prefix: location_prefix,
    )
  end

  # This line number needs to be the location of the method `test_it_passes` in
  # the anonymous class `test_class` declaration below.
  let(:location_line_number) { 23 }

  let(:test_class) {
    Class.new(Minitest::Test) do
      def test_it_passes
      end
    end
  }

  let(:location_prefix) { nil }

  let(:example) do
    test_class.new("test_it_passes")
  end

  before do
    example.failures << failure
    example.failures << another_failure
  end

  # failure is either Minitest::Assertion or Minitest::UnexpectedError object. 
  # ref: https://github.com/minitest/minitest/blob/0984e29995a5c0f4dcf3c185442bcb4f493ed5e3/lib/minitest/test.rb#L198
  let(:failure) { instance_double(Minitest::Assertion, message: "test for invalid character'\xC8'\n    Expected: true\n    Actual: false", backtrace: backtrace, result_code: "F") }
  let(:another_failure) { instance_double(Minitest::Assertion, message: "another test\n    Expected thing to be truthy.", backtrace: backtrace) }

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

  let(:tags) { nil }

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

    describe "failure_reason" do
      it "only contains the first line of failure message" do
        example.failures << failure
        failure_reason = trace.as_hash[:failure_reason]
        expect(failure_reason).to include("test for invalid character")
        expect(failure_reason).not_to include("Expected: true")
      end
    end

    describe "failure_expanded" do
      it "contains all failures" do
        failure_expanded = trace.as_hash[:failure_expanded]
        expect(failure_expanded.count).to eq(2)
      end

      it "contains expanded message and backtrace for each failure" do
        failure_expanded = trace.as_hash[:failure_expanded]
        expect(failure_expanded).to all( include(:expanded, backtrace: backtrace) )
      end

      it "does not contain the first line of failure message for first failure" do
        first_failure = trace.as_hash[:failure_expanded][0][:expanded].to_s
        expect(first_failure).not_to include("test for invalid character")
        expect(first_failure).to include("Expected: true", "Actual: false")
      end

      it "contains the all lines of failure message for the other failures" do
        another_failure = trace.as_hash[:failure_expanded][1][:expanded].to_s
        expect(another_failure).to include("another test","Expected thing to be truthy.")
      end
    end

    it "sets the filename and location" do
      expect(trace.as_hash).to include(
        file_name: "./spec/test_collector/minitest_plugin/trace_spec.rb",
        location: "./spec/test_collector/minitest_plugin/trace_spec.rb:#{location_line_number}",
      )
    end

    describe "when in rails" do
      let(:rails) { double("Rails", root: Pathname.new("#{Dir.getwd}/spec")) }

      it "strips Rails.root from the filename" do
        stub_const("Rails", rails)
        expect(trace.as_hash[:file_name]).to eq("./test_collector/minitest_plugin/trace_spec.rb")
      end
    end

    describe "with a location_prefix" do
      let(:location_prefix) { "some/prefix" }
      it "prepends the location_prefix to the file_name and location" do
        expect(trace.as_hash).to include(
          file_name: "some/prefix/spec/test_collector/minitest_plugin/trace_spec.rb",
          location: "some/prefix/spec/test_collector/minitest_plugin/trace_spec.rb:#{location_line_number}",
        )
      end
    end

    context "with tags" do
      let(:tags) { { "hello" => "world" } }

      it "includes the tags" do
        expect(trace.as_hash[:tags]).to eq({ "hello" => "world" })
      end
    end
  end
end
