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
          Buildkite::TestCollector.session.add_example_to_send_queue(result.source_location)
        end
      end
    end

    def report
      super

      if Buildkite::TestCollector.session
        Buildkite::TestCollector.session.send_remaining_data
        Buildkite::TestCollector.session.close
      end
    end
  end
end
