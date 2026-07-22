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

    # TE-6490 PoC: mint one span_trace_key per test and carry it as an execution tag,
    # so the OTel span stream can be joined back to this execution on the backend.
    if Buildkite::TestCollector::OTel.enabled?
      span_trace_key = Buildkite::TestCollector::UUID.call
      tags["span_trace_key"] = span_trace_key
      Buildkite::TestCollector::OTel.current_key = span_trace_key
    end

    # example.run can raise errors (including from other middleware/hooks) so clean up in `ensure`.
    begin
      Buildkite::TestCollector::OTel.in_test_span(
        name: "test.execution",
        attributes: {
          "test.name" => example.full_description,
          "test.id" => example.id,
          "test.file" => example.metadata[:file_path],
        }
      ) do
        example.run
      end
    ensure
      Thread.current[:_buildkite_tracer] = nil
      Thread.current[:_buildkite_tags] = nil
      Buildkite::TestCollector::OTel.current_key = nil

      tracer.finalize

      trace = Buildkite::TestCollector::RSpecPlugin::Trace.new(
        example,
        history: tracer.history,
        tags: tags,
        location_prefix: Buildkite::TestCollector.location_prefix
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

  # TE-6490 PoC: flush and shut down the OTel exporter so spans are delivered
  # before the process exits.
  config.after(:suite) do
    Buildkite::TestCollector::OTel.force_flush
    Buildkite::TestCollector::OTel.shutdown
  end
end

Buildkite::TestCollector.enable_tracing!
