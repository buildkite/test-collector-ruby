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
      return false unless Buildkite::TestCollector.api_token
      return false unless suite_url

      @output.puts "\n\nTest Analytics failures:\n\n"

      @failed_examples.each do |example|
        scope_name_digest = generate_scope_name_digest(example)
        url = suite_url + "/tests/#{scope_name_digest}?scope_name_digest=true"
        hyperlink = "\x1b[31m#{%(\x1b]1339;url=#{url};content="#{example[:scope]} #{example[:name]}"\x07)}\x1b[0m"
        @output.puts hyperlink
      end
    end

    private

    def suite_url
      response = Buildkite::TestCollector::Uploader.response
      res = JSON.parse(response.body)
      res['suite_url']
    rescue StandardError => e
      @output.puts 'Error: cannot find test suite'
      @output.puts e
    end

    def generate_scope_name_digest(result)
      Digest::SHA256.hexdigest(result[:scope].to_s + result[:name].to_s)
    end
  end
end
