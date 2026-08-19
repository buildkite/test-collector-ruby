# frozen_string_literal: true

module Buildkite::TestCollector::RSpecPlugin
  # RSpec integration for OTLP-only result submission. Nothing is uploaded as
  # JSON and none of the legacy tracing is installed: every example gets one
  # OpenTelemetry `test.execution` span carrying everything the server needs
  # to synthesize the test execution, and that's the gem's whole job.
  module OTelOnly
    class << self
      def install!
        RSpec.configure do |config|
          # Deferred from configure until before(:suite), after application
          # and support files have loaded, same as the otel_enabled mode.
          config.before(:suite) do
            Buildkite::TestCollector.start_otel
          end

          config.around(:each) do |example|
            Buildkite::TestCollector::RSpecPlugin::OTelOnly.trace(example) { example.run }
          end

          # before/after(:suite) can run more than once in a single process
          # (warm test pools re-run suites), so flush here but keep the
          # exporter alive until the process exits.
          config.after(:suite) do
            Buildkite::TestCollector::OTel.force_flush
          end
        end

        at_exit { Buildkite::TestCollector::OTel.shutdown }
      end

      def trace(example)
        tags = {}

        # _buildkite prefix reduces chance of collisions in this almost-global
        # (per-fiber) namespace. This keeps Buildkite::TestCollector.tag_execution
        # working: tags collected here land on the span when it finishes.
        Thread.current[:_buildkite_tags] = tags

        span, _trace_id = Buildkite::TestCollector::OTel.start_test_span
        raised = nil

        begin
          Buildkite::TestCollector::OTel.with_test_span(span) { yield }
        rescue Exception => e # rubocop:disable Lint/RescueException
          raised = e
          raise
        ensure
          Thread.current[:_buildkite_tags] = nil
          finish(span, example, raised, tags) if span
        end
      end

      private

      # Describes the finished example onto the span. Runs inside an ensure,
      # so nothing here may raise into the test run: the describing work is
      # delegated to OTel.finish_test_span, which fails open.
      def finish(span, example, raised, tags)
        trace = Buildkite::TestCollector::RSpecPlugin::Trace.new(
          example,
          history: {},
          tags: tags,
          location_prefix: Buildkite::TestCollector.location_prefix,
          otel_only: true,
        )

        exception = raised || example.exception
        if exception
          trace.otel_exception = exception
          begin
            trace.failure_reason, trace.failure_expanded = failure_info(exception)
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not describe test failure: #{e.class}: #{e.message}"
          end
        end

        Buildkite::TestCollector::OTel.finish_test_span(span, test: trace)
      end

      # No reporter runs in OTLP-only mode, so derive the failure details from
      # the exception itself, the way RSpec's own formatters do for multiple
      # failures (summary plus one entry per exception).
      def failure_info(exception)
        exceptions = exception.respond_to?(:all_exceptions) ? Array(exception.all_exceptions) : [exception]
        exceptions = [exception] if exceptions.empty?

        reason = exception.respond_to?(:summary) ? exception.summary : exception.message
        expanded = exceptions.map do |error|
          {
            expanded: [error.message.to_s],
            backtrace: RSpec.configuration.backtrace_formatter.format_backtrace(error.backtrace),
          }
        end

        [reason.to_s, expanded]
      end
    end
  end
end
