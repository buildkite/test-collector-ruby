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
        name: example.description
      }
    end

    def dump_summary(_notification)
      # Do not display summary if no failed examples
      return false unless @failed_examples.length.positive?

      # Check if a Test Analytics token is set
      return false unless Buildkite::TestCollector.api_token

      # If the suite_url fails to be generated, then we are unable to create the test links
      return false unless (url = suite_url)

      @output.puts "\n\nTest Analytics failures:\n\n"

      @failed_examples.each do |example|
        scope_name_digest = generate_scope_name_digest(example)
        test_url = "#{url}/tests/#{scope_name_digest}"
        hyperlink = "\x1b[31m#{%(\x1b]1339;url=#{test_url};content="#{example[:scope]} #{example[:name]}"\x07)}\x1b[0m"
        @output.puts hyperlink
      end
    end

    private

    def suite_url
      response = Buildkite::TestCollector::Uploader.response
      res = JSON.parse(response.body)
      res['suite_url']
    rescue StandardError => e
      $stderr.puts e
    end

    def generate_scope_name_digest(result)
      Digest::SHA256.hexdigest(result[:scope].to_s + result[:name].to_s)
    end
  end
end
