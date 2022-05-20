# frozen_string_literal: true

module Buildkite::Collector
  class Object
    module CustomObjectSleep
      def sleep(duration)
        tracer = Buildkite::Collector::Uploader.tracer
        tracer&.enter("sleep")

        super
      ensure
        tracer&.leave
      end
    end

    def self.configure
      ::Object.prepend(CustomObjectSleep)
    end
  end
end
