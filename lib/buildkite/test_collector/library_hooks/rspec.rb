# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require_relative "../rspec_plugin/reporter"
require_relative "../rspec_plugin/otel_reporter"
require_relative "../rspec_plugin/trace"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

RSpec.configure do |config|
  config.before(:suite) do
    Buildkite::TestCollector.start_otel

    # OTelReporter first: it finishes the example's span (and settles the
    # history's duration) before Reporter queues the example for upload.
    config.add_formatter Buildkite::TestCollector::RSpecPlugin::OTelReporter
    config.add_formatter Buildkite::TestCollector::RSpecPlugin::Reporter
  end

  config.around(:each) do |example|
    tracer = Buildkite::TestCollector::Tracer.new(
      min_duration: Buildkite::TestCollector.trace_min_duration,
    )

    tags = {}

    # _buildkite prefix reduces chance of collisions in this almost-global (per-fiber) namespace.
    Thread.current[:_buildkite_tracer] = tracer
    Thread.current[:_buildkite_tags] = tags

    otel_span, trace_id = Buildkite::TestCollector::OTel.start_test_span

    # example.run can raise errors (including from other middleware/hooks) so clean up in `ensure`.
    begin
      Buildkite::TestCollector::OTel.with_test_span(otel_span) { example.run }
    ensure
      Thread.current[:_buildkite_tracer] = nil
      Thread.current[:_buildkite_tags] = nil

      tracer.finalize

      trace = Buildkite::TestCollector::RSpecPlugin::Trace.new(
        example,
        history: tracer.history,
        tags: tags,
        location_prefix: Buildkite::TestCollector.location_prefix,
        external_id: Buildkite::TestCollector::UUID.v7,
        trace_id: trace_id,
      )

      # Left open for OTelReporter to finish once RSpec settles the result;
      # the end timestamp keeps the span timing the example itself.
      if otel_span
        trace.otel_span = otel_span
        trace.otel_end_timestamp = Buildkite::TestCollector::OTel.current_timestamp
      end

      Buildkite::TestCollector.uploader.traces[example.id] = trace
    end
  end

  config.after(:suite) do
    Buildkite::TestCollector::OTel.shutdown

    if Buildkite::TestCollector.artifact_path
      filename = File.join(Buildkite::TestCollector.artifact_path, "buildkite-test-collector-rspec-#{Buildkite::TestCollector::UUID.call}.json.gz")
      data_set = { results: Buildkite::TestCollector.uploader.traces.values.map(&:as_hash) }
      File.open(filename, "wb") do |f|
        gz = Zlib::GzipWriter.new(f)
        gz.write(data_set.to_json)
        gz.close
      end
    end
  end
end

Buildkite::TestCollector.enable_tracing!
