module Buildkite::TestCollector
  class Error < StandardError; end
  class TimeoutError < ::Timeout::Error; end
end
