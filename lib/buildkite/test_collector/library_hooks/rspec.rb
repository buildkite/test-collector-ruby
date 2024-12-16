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

    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
    # It's important to use begin/ensure here, because otherwise if other hooks fail,
    # the cleanup code won't run, meaning we will miss some data.
    #
    # Having said that, this behavior isn't documented by RSpec.
    begin
      example.run
    ensure
      Thread.current[:_buildkite_tracer] = nil

      tracer.finalize

      trace = Buildkite::TestCollector::RSpecPlugin::Trace.new(example, history: tracer.history)
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
end

Buildkite::TestCollector.enable_tracing!
