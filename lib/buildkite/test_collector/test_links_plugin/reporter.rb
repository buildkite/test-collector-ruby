# frozen_string_literal: true

module Buildkite::TestCollector::TestLinksPlugin
  class Reporter
    RSpec::Core::Formatters.register self, :example_failed, :dump_summary

    def initialize(output)
      Buildkite::TestCollector.session = Buildkite::TestCollector::Session.new
      @output = output
      @failed_examples = []
    end

    def example_failed(notification)
      example = notification.example

      @failed_examples << {
        scope: example.example_group.metadata[:full_description],
        name: example.description,
        example: example.example_group.example
      }
    end

    def dump_summary(_notification)
      # Buildkite::TestCollector.session.send_remaining_data
      @output.puts Buildkite::TestCollector.session.upload_response.inspect

      @output.puts "\n\nTest Analytics failures:\n"

      @failed_examples.each do |example|
        scope_name_digest = generate_scope_name_digest(example)
        url = "http://buildkite.localhost/organizations/buildkite/analytics/suites/ruby-rbenv-example/tests/#{scope_name_digest}"
        content = "#{example[:scope]} #{example[:name]}"

        @output.puts "\e]1339;url=#{url};content=#{content}\a"
      end
    end

    def generate_scope_name_digest(result)
      Digest::SHA256.hexdigest(result[:scope].to_s + result[:name].to_s)
    end
  end
end
