# frozen_string_literal: true

reporter_class = Buildkite::TestCollector::OTel.const_get(:RootSpanMetricsReporter, false)

RSpec.describe reporter_class do
  subject(:reporter) { described_class.new }

  describe "#add_to_counter" do
    it "warns only once when root spans are dropped" do
      expect do
        2.times do
          reporter.add_to_counter(
            "otel.bsp.dropped_spans",
            increment: 3,
            labels: { "reason" => "buffer-full" },
          )
        end
      end.to output(
        "[buildkite-test_collector] OpenTelemetry dropped 3 test.execution span(s) " \
          "(buffer-full); some test executions may be missing\n"
      ).to_stderr
    end

    it "ignores other processor metrics" do
      expect do
        reporter.add_to_counter("otel.bsp.export.success")
      end.not_to output.to_stderr
    end
  end
end
