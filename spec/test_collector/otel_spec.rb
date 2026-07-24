# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::OTel do
  describe ".in_test_span" do
    let(:tracer) { double("OpenTelemetry tracer") }
    let(:external_id) { "019c8d97-f9ad-75a5-8173-dc6c1b54b901" }

    before do
      described_class.instance_variable_set(:@enabled, true)
      described_class.instance_variable_set(:@tracer, tracer)
    end

    after do
      described_class.instance_variable_set(:@enabled, false)
      described_class.instance_variable_set(:@tracer, nil)
    end

    it "puts the execution external ID on the root span" do
      expect(tracer).to receive(:in_span).with(
        "test.execution",
        attributes: {
          "execution.externalId" => external_id,
          "test.name" => "example",
        },
        kind: :internal,
      ).and_yield(double("span"))

      yielded = false
      described_class.in_test_span(
        name: "test.execution",
        external_id: external_id,
        attributes: { "test.name" => "example" },
      ) do
        yielded = true
      end

      expect(yielded).to eq(true)
    end
  end
end
