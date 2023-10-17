# frozen_string_literal: true

module Buildkite::TestCollector::TestLinksPlugin
  class Reporter
    RSpec::Core::Formatters.register self, :dump_failures

    def initialize(output)
      @output = output
    end

    def dump_failures(notification)
      # Do not display summary if no failed examples
      return false unless notification.failed_examples.length.positive?

      # Check if a Test Analytics token is set
      return false unless Buildkite::TestCollector.api_token

      # If the suite_url fails to be generated, then we are unable to create the test links
      return false unless (url = suite_url)

      @output << "\n\nTest Analytics failures:\n\n\t"

      @output << notification.failed_examples.map do |example|
        failed_example_output(example, url)
      end.join("\n\t")

      @output << "\n\n"
    end

    private

    def suite_url
      response = Buildkite::TestCollector.uploader.summary
      res = JSON.parse(response.body)
      res['suite_url']
    rescue StandardError => e
      $stderr.puts e
    end

    def generate_scope_name_digest(scope, name)
      Digest::SHA256.hexdigest(scope.to_s + name.to_s)
    end

    def failed_example_output(example, url)
      scope = example.example_group.metadata[:full_description]
      name = example.description
      scope_name_digest = generate_scope_name_digest(scope, name)
      test_url = "#{url}/tests/#{scope_name_digest}"
      "\x1b[31m#{%(\x1b]1339;url=#{test_url};content="#{scope} #{name}"\x07)}\x1b[0m"
    end
  end
end
