# frozen_string_literal: true

require_relative "trace"

module Buildkite::TestCollector::RSpecPlugin
  # In OTLP-only mode the span carries everything a JSON upload would have
  # said, so the server can synthesize the execution from the span alone
  # (`buildkite.execution.via` opts in to that). A subclass so the standard
  # Trace stays untouched for the JSON upload paths.
  class OTelOnlyTrace < Trace
    def otel_attributes
      file_path = strip_invalid_utf8_chars(prepend_location_prefix(file_name))
      attributes = {
        "buildkite.execution.via" => "otlp",
        "buildkite.test.scope" => strip_invalid_utf8_chars(scope),
        "buildkite.test.name" => strip_invalid_utf8_chars(name),
        "test.suite.name" => strip_invalid_utf8_chars(scope),
        "test.case.name" => strip_invalid_utf8_chars(example.full_description),
        "code.file.path" => file_path,
        "code.line.number" => source_line_number,
      }

      # Tags set through Buildkite::TestCollector.tag_execution become
      # buildkite.tag.-prefixed span attributes, which the server strips and
      # turns back into execution tags.
      tags&.each do |key, value|
        attributes["buildkite.tag.#{key}"] = strip_invalid_utf8_chars(value.to_s)
      end

      attributes.reject { |_, value| value.nil? }
    end

    # The failure summary, destined for the span's error status description.
    def otel_failure_reason
      strip_invalid_utf8_chars(failure_reason) if failure_reason
    end

    # One semconv exception event per failure, built from the same detail the
    # JSON upload would have carried as failure_expanded.
    def otel_exception_events
      (failure_expanded || []).filter_map do |failure|
        message = Array(failure[:expanded]).join("\n")
        stacktrace = Array(failure[:backtrace]).join("\n")
        attributes = {}
        attributes["exception.message"] = strip_invalid_utf8_chars(message) unless message.empty?
        attributes["exception.stacktrace"] = strip_invalid_utf8_chars(stacktrace) unless stacktrace.empty?
        attributes unless attributes.empty?
      end
    end
  end

  # RSpec integration for OTLP-only result submission. Nothing is uploaded as
  # JSON and none of the legacy tracing is installed: every example gets one
  # OpenTelemetry `test.execution` span carrying everything the server needs
  # to synthesize the test execution, and that's the gem's whole job.
  module OTelOnly
    # Finishes each example's span from RSpec's reporter notifications, which
    # fire after every around hook has unwound: RSpec has settled the
    # example's final result by then, so the span's classification reads that
    # verdict instead of unwind-time heuristics. Registered as a formatter by
    # install!'s before(:suite), mirroring how the JSON modes add theirs.
    class Reporter
      RSpec::Core::Formatters.register self, :example_passed, :example_failed, :example_pending

      def initialize(_output)
      end

      def handle_example(notification)
        Buildkite::TestCollector::RSpecPlugin::OTelOnly.finish_example(notification.example)
      end

      alias_method :example_passed, :handle_example
      alias_method :example_failed, :handle_example
      alias_method :example_pending, :handle_example
    end

    class << self
      def install!
        RSpec.configure do |config|
          # Deferred from configure until before(:suite), after application
          # and support files have loaded, same as the otel_enabled mode.
          # The formatter is also added here rather than at configure time,
          # so it does not displace RSpec's default progress output.
          config.before(:suite) do
            Buildkite::TestCollector.start_otel
            config.add_formatter Buildkite::TestCollector::RSpecPlugin::OTelOnly::Reporter
          end

          # Never runs for pre-skipped examples (skip/xit), so they produce no
          # execution — accepted, matching the JSON upload paths.
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

        begin
          Buildkite::TestCollector::OTel.with_test_span(span) { yield }
        ensure
          Thread.current[:_buildkite_tags] = nil
          defer_finish(example, span, tags) if span
        end
      end

      # Called from the reporter's notifications, after every around hook has
      # unwound: RSpec has settled the example's result and recorded any
      # exception another hook raised after example.run, so the span's
      # classification and failure details rest on the final verdict. Fails
      # open: OTel.finish_test_span never raises into the reporter.
      def finish_example(example)
        trace = pending_traces.delete(example.id)
        return unless trace

        exception = example.exception
        if example.execution_result.status == :failed && exception
          begin
            trace.failure_reason, trace.failure_expanded = failure_info(exception)
          rescue StandardError => e
            warn "[buildkite-test_collector] Could not describe test failure: #{e.class}: #{e.message}"
          end
        end

        Buildkite::TestCollector::OTel.finish_test_span(
          trace.otel_span,
          test: trace,
          end_timestamp: trace.otel_end_timestamp,
        )
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not finish the OpenTelemetry test span: #{e.class}: #{e.message}"
      end

      private

      # Describes the example onto a trace at hook-unwind time, but leaves the
      # span open for finish_example: RSpec only settles the example's result
      # (and records exceptions other around hooks raise) after this hook has
      # returned. The end timestamp is captured here so the span still times
      # the example itself, not the hooks and reporting that follow. Runs
      # inside an ensure, so nothing here may raise into the test run.
      def defer_finish(example, span, tags)
        trace = Buildkite::TestCollector::RSpecPlugin::OTelOnlyTrace.new(
          example,
          history: {},
          tags: tags,
          location_prefix: Buildkite::TestCollector.location_prefix,
        )
        trace.otel_span = span
        trace.otel_end_timestamp = Buildkite::TestCollector::OTel.current_timestamp
        pending_traces[example.id] = trace
      rescue StandardError => e
        warn "[buildkite-test_collector] Could not describe the test onto its OpenTelemetry span: #{e.class}: #{e.message}"
        Buildkite::TestCollector::OTel.finish_test_span(span)
      end

      # Spans handed off from the around hook, awaiting their example's
      # reporter notification. One example is in flight at a time per process,
      # so this stays small; an entry only lingers if the run aborts before
      # its notification fires, in which case the span is never exported.
      def pending_traces
        @pending_traces ||= {}
      end

      # Derives the failure details from the exception itself, the way RSpec's
      # own formatters do for multiple failures (summary plus one entry per
      # exception).
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
