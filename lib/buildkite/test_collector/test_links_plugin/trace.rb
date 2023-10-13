# frozen_string_literal: true

module Buildkite::TestCollector::TestLinksPlugin
  class Trace
    attr_accessor :example

    def initialize(example)
      @example = example
    end

    def as_hash
      strip_invalid_utf8_chars(
        scope: example.example_group.metadata[:full_description],
        name: example.description,
        example: example
      ).with_indifferent_access.select { |_, value| !value.nil? }
    end

    private

    def strip_invalid_utf8_chars(object)
      if object.is_a?(Hash)
        Hash[object.map { |key, value| [key, strip_invalid_utf8_chars(value)] }]
      elsif object.is_a?(Array)
        object.map { |value| strip_invalid_utf8_chars(value) }
      elsif object.is_a?(String)
        object.encode('UTF-8', :invalid => :replace, :undef => :replace)
      else
        object
      end
    end
  end
end
