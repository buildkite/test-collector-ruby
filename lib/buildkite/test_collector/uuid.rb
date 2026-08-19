# frozen_string_literal: true

require "securerandom"

class Buildkite::TestCollector::UUID
  GET_UUID = SecureRandom.method(:uuid)
  GET_UUID_V7 = SecureRandom.method(:uuid_v7)
  private_constant :GET_UUID, :GET_UUID_V7

  def self.call
    GET_UUID.call
  end

  # Time-sortable UUID used for execution external IDs, giving storage
  # locality when persisted (e.g. as a ClickHouse primary key component).
  def self.v7
    GET_UUID_V7.call
  end
end
