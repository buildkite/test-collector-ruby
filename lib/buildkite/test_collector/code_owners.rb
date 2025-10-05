# frozen-string-literal: true

module Buildkite
  module TestCollector
    class CodeOwners
      include Enumerable

      class Rule
        FNMATCH_FLAGS = ::File::FNM_DOTMATCH | ::File::FNM_PATHNAME

        attr_reader :glob, :owners, :pattern

        def initialize(glob:, owners:)
          @glob = glob
          @owners = owners
          @pattern = normalize_pattern(glob)
        end

        def match?(pathname)
          pathname = "/#{pathname}" unless pathname.start_with?("/")
          ::File.fnmatch?(pattern, pathname, FNMATCH_FLAGS)
        end

        private

        # From https://gitlab.com/gitlab-org/gitlab/-/blob/83339741b99c6d773d22406e60af1f197004fbb5/ee/lib/gitlab/code_owners/file.rb#L175
        def normalize_pattern(pattern)
          # Remove `\` when escaping `\#`
          pattern = pattern.sub(/\A\\#/, "#")
          # Replace all whitespace preceded by a \ with a regular whitespace
          pattern = pattern.gsub(/\\\s+/, " ")

          return "/**/*" if pattern == "*"

          unless pattern.start_with?("/")
            pattern = "/**/#{pattern}"
          end

          if pattern.end_with?("/")
            pattern = "#{pattern}**/*"
          end

          pattern
        end
      end

      attr_reader :raw

      def initialize(raw)
        @raw = raw
      end

      def each(&block)
        rules.each(&block)
      end

      # Returns a single Rule matching the pathname, or nil if no matching rule is found.
      # CODEOWNERS rules are matched "last declared rule wins".
      def find_rule(pathname)
        find do |rule|
          rule.match?(sanitize_pathname(pathname))
        end
      end

      private

      def sanitize_pathname(pathname)
        # Remove leading ./ if present
        pathname.sub(/^.\//, "")
      end

      def rules
        @rules ||= build_rules
      end

      def build_rules
        # CODEOWNERS matches are "last declared rule wins". So process the
        # CODEOWNERS input in reverse so it's natively in the right order for
        # `find`.
        raw.reverse.filter_map do |line|
          # Strip out comments, leading and trailing whitespace
          line = line.sub(/\#.*/, "").strip
          # ... and skip the resulting line if it's empty
          next if line == ""

          glob, *owners = line.split(/\s+/)
          Rule.new(glob:, owners:)
        end
      end
    end
  end
end
