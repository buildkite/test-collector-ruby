# frozen_string_literal: true

require "securerandom"

class Buildkite::TestCollector::UUID
  GET_UUID = SecureRandom.method(:uuid)
  # `uuid_v7` is only available on Ruby 3.3+; fall back to UUIDv4 on older Rubies.
  # Once we require Ruby 3.3+ (planned alongside the OTel work), drop this
  # fallback and just call SecureRandom.uuid_v7 directly.
  GET_UUID_V7 = SecureRandom.respond_to?(:uuid_v7) ? SecureRandom.method(:uuid_v7) : GET_UUID
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
