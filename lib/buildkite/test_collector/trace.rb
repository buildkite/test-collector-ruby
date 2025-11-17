# frozen_string_literal: true

module Buildkite
  module TestCollector
    class Trace
      def as_hash
        strip_invalid_utf8_chars(
          scope: scope,
          name: name,
          location: prepend_location_prefix(location),
          file_name: prepend_location_prefix(file_name),
          result: result,
          failure_reason: failure_reason,
          failure_expanded: failure_expanded,
          history: history,
          tags: tags,
        ).select { |_, value| !value.nil? }
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

      def prepend_location_prefix(file_name)
        return file_name unless file_name && location_prefix

        Pathname.new(location_prefix).join(
          Pathname.new(file_name)
        ).to_s
      end
    end
  end
end
