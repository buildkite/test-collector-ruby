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

    # Use one time-sortable ID for both independently ingested records so they can be joined.
    external_id = Buildkite::TestCollector::UUID.v7 if Buildkite::TestCollector::OTel.enabled?
    file_path = example.metadata[:file_path]&.sub(%r{\A\./}, "")

    # example.run can raise errors (including from other middleware/hooks) so clean up in `ensure`.
    begin
      Buildkite::TestCollector::OTel.in_test_span(
        name: "test.execution",
        external_id: external_id,
        attributes: {
          "test.case.name" => example.full_description,
          "test.suite.name" => example.example_group.metadata[:full_description],
          "code.file.path" => file_path,
          "code.line.number" => example.metadata[:line_number],
          "buildkite.test.case.id" => example.id,
          "buildkite.test.runner.name" => "rspec",
          "buildkite.test.runner.version" => RSpec::Core::Version::STRING,
        }
      ) do |span|
        begin
          example.run
        ensure
          execution_result = example.execution_result
          result = if execution_result.pending_message && !execution_result.pending_fixed?
            "skipped"
          elsif execution_result.exception
            "failed"
          else
            "passed"
          end
          Buildkite::TestCollector::OTel.record_test_result(
            span,
            result: result,
            tags: tags,
          )
        end
      end
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
