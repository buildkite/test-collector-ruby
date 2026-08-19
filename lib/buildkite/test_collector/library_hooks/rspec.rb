# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require_relative "../rspec_plugin/reporter"
require_relative "../rspec_plugin/trace"

Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader

RSpec.configure do |config|
  config.before(:suite) do
    Buildkite::TestCollector.start_otel

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

      # Finish the span here rather than from the reporter, so its duration is
      # the example itself and not the reporting that follows. When there is a
      # span, report what it timed as the execution's duration too, so the two
      # never disagree. `end_at` moves with it, so the history still describes
      # itself and its children still sit inside it.
      span_duration = Buildkite::TestCollector::OTel.finish_test_span(otel_span, test: trace)
      if span_duration
        trace.history[:duration] = span_duration
        trace.history[:end_at] = trace.history[:start_at] + span_duration
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
