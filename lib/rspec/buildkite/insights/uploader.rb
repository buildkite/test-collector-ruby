# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require_relative "tracer"

require "active_support"
require "active_support/notifications"

module RSpec::Buildkite::Insights
  class Uploader
    class Trace
      attr_reader :example, :history
      def initialize(example, history)
        @example = example
        @history = history
      end

      def failure_message
        case example.exception
        when RSpec::Expectations::ExpectationNotMetError
          example.exception.message
        when Exception
          "#{example.exception.class}: #{example.exception.message}"
        end
      end

      def result_state
        case example.execution_result.status
        when :passed; "passed"
        when :failed; "failed"
        when :pending; "skipped"
        end
      end

      def as_json
        {
          scope: example.example_group.metadata[:full_description],
          name: example.description,
          identifier: example.id,
          location: example.location,
          result: result_state,
          failure: failure_message,
          history: history,
        }
      end
    end

    def self.traces
      @traces ||= []
    end

    def self.configure
      uploader = self

      RSpec.configure do |config|
        config.around(:each) do |example|
          tracer = RSpec::Buildkite::Insights::Tracer.new

          Thread.current[:_buildkite_tracer] = tracer
          example.run
          Thread.current[:_buildkite_tracer] = nil

          tracer.finalize

          uploader.traces << RSpec::Buildkite::Insights::Uploader::Trace.new(example, tracer.history)
        end

        config.after(:suite) do
          filename = "tmp/bk-insights-#{$$}.json.gz"
          data_set = { results: uploader.traces.map(&:as_json) }

          File.open(filename, "wb") do |f|
            gz = Zlib::GzipWriter.new(f)
            gz.write(data_set.to_json)
            gz.close
          end
        end
      end

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        tracer&.backfill(:sql, finish - start, { query: payload[:sql] })
      end
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end
  end
end
