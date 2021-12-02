# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

module RSpec::Buildkite::Analytics
  class Tracer
    class Span
      attr_accessor :section, :start_at, :end_at, :detail, :children

      def initialize(section, start_at, end_at, detail)
        @section = section
        @start_at = start_at
        @end_at = end_at
        @detail = detail
        @children = []
      end

      def as_hash
        {
          section: section,
          start_at: start_at,
          end_at: end_at,
          duration: end_at - start_at,
          detail: detail,
          children: children.map(&:as_hash),
        }.with_indifferent_access
      end
    end

    def initialize
      @top = Span.new(:top, Concurrent.monotonic_time, nil, {})
      @stack = [@top]
    end

    def enter(section, **detail)
      new_entry = Span.new(section, Concurrent.monotonic_time, nil, detail)
      current_span.children << new_entry
      @stack << new_entry
    end

    def leave
      current_span.end_at = Concurrent.monotonic_time
      @stack.pop
    end

    def backfill(section, duration, **detail)
      new_entry = Span.new(section, Concurrent.monotonic_time - duration, Concurrent.monotonic_time, detail)
      current_span.children << new_entry
    end

    def current_span
      @stack.last
    end

    def finalize
      raise "Stack not empty" unless @stack.size == 1
      @top.end_at = Concurrent.monotonic_time
      self
    end

    def history
      @top.as_hash
    end
  end
end
