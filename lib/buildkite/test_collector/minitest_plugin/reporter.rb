# frozen_string_literal: true

module Buildkite::TestCollector::MinitestPlugin
  class Reporter < Minitest::StatisticsReporter
    def initialize(io, options)
      super
      @io = io
      @options = options
    end

    def record(result)
      super

      if Buildkite::TestCollector.uploader
        if trace = Buildkite::TestCollector.uploader.traces[result.source_location]
          Buildkite::TestCollector.session&.write_result(trace)
        end
      end
    end

    def report
      super

      if Buildkite::TestCollector.session.present?
        examples_count = {
          examples: count,
          failed: failures,
          pending: skips,
          errors_outside_examples: 0, # Minitest does not report this
        }

        Buildkite::TestCollector.session.close(examples_count)
      end
    end
  end
end
