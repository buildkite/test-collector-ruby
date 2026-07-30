# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require_relative "../rspec_plugin/reporter"
require_relative "../rspec_plugin/trace"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

RSpec.configure do |config|
  config.before(:suite) do
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

    external_id = nil
    otel_span = nil
    if Buildkite::TestCollector::OTel.enabled?
      begin
        # Use one time-sortable ID for both independently ingested records so they can be joined.
        candidate_external_id = Buildkite::TestCollector::UUID.v7
        otel_span = Buildkite::TestCollector::OTel.start_test_span(
          name: "test.execution",
          external_id: candidate_external_id,
        )
        external_id = candidate_external_id if Buildkite::TestCollector::OTel.sampled?(otel_span)
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not start OpenTelemetry test span: #{e.class}: #{e.message}"
      end
    end

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
        external_id: external_id,
        otel_span: otel_span,
      )

      Buildkite::TestCollector.uploader.traces[example.id] = trace
    end
  end

  config.after(:suite) do
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

  config.after(:suite) do
    Buildkite::TestCollector::OTel.force_flush
    Buildkite::TestCollector::OTel.shutdown
  end
end

Buildkite::TestCollector.enable_tracing!
