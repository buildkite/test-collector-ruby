# frozen_string_literal: true

module Buildkite::Collector::MinitestPlugin
  class Reporter < Minitest::StatisticsReporter
    def initialize(io, options)
      super
      @io = io
      @options = options
    end

    def record(result)
      super

      if trace = Buildkite::Collector.uploader.traces[result.source_location]
        Buildkite::Collector.session&.write_result(trace)
      end
    end

    def report
      super

      if Buildkite::Collector.session.present?
        examples_count = {
          examples: count,
          failed: failures,
          pending: skips,
          errors_outside_examples: 0, # Minitest does not report this
        }

        Buildkite::Collector.session.close(examples_count)
      end
    end
  end
end
