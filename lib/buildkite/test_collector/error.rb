module Buildkite::TestCollector
  class Error < StandardError; end
  class TimeoutError < ::Timeout::Error; end
  class UnsupportedFrameworkError < Error; end
end
