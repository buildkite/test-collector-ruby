# frozen_string_literal: true

require "securerandom"

class Buildkite::TestCollector::UUID
  GET_UUID = SecureRandom.method(:uuid)
  private_constant :GET_UUID

  def self.call
    GET_UUID.call
  end
end
