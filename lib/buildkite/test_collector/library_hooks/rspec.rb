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
    FAILED_TESTS = [
      "./spec/helpers/emoji_helper_spec.rb[1:2:1]", 
      "./spec/features/usage/test_executions_spec.rb[1:4:1]",
      "./spec/api/api/hello_world_spec.rb[1:1:1]"
    ]
    $stdout.puts "🐛 start of around method" if FAILED_TESTS.include?(example.id)
    
    $stdout.puts "🐛 create new tracer object" if FAILED_TESTS.include?(example.id)
    tracer = Buildkite::TestCollector::Tracer.new


    # The _buildkite prefix here is added as a safeguard against name collisions
    # as we are in the main thread
    Thread.current[:_buildkite_tracer] = tracer
    $stdout.puts Thread.current if FAILED_TESTS.include?(example.id)
    $stdout.puts "🐛 run the test" if FAILED_TESTS.include?(example.id)
    example.run
    $stdout.puts "🐛 end of run the test" if FAILED_TESTS.include?(example.id)
    Thread.current[:_buildkite_tracer] = nil

    $stdout.puts "🐛 finalize the tracer" if FAILED_TESTS.include?(example.id)
    tracer.finalize

    $stdout.puts "🐛 create new traces object" if FAILED_TESTS.include?(example.id)
    trace = Buildkite::TestCollector::RSpecPlugin::Trace.new(example, history: tracer.history)
    $stdout.puts "🐛 put test in the traces" if FAILED_TESTS.include?(example.id)
    Buildkite::TestCollector.uploader.traces[example.id] = trace

    $stdout.puts "🐛 end of around method" if FAILED_TESTS.include?(example.id)
    $stdout.puts Thread.current if FAILED_TESTS.include?(example.id)
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
