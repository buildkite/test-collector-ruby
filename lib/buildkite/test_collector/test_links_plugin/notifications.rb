# frozen_string_literal: true

require 'rspec/core/notifications'

module Buildkite::TestCollector::TestLinksPlugin
  class CustomNotification < RSpec::Core::Notifications::ExamplesNotification
    def fully_formatted_failed_examples(colorizer=::RSpec::Core::Formatters::ConsoleCodes)
      formatted = "\nFailures:\n"

      failure_notifications.each_with_index do |failure, index|
        formatted += failure.fully_formatted(index.next, colorizer)
        formatted += failed_example_output(failure)
      end

      formatted
    end

    private

    def generate_scope_name_digest(scope, name)
      Digest::SHA256.hexdigest(scope + name)
    end

    def failed_example_output(example)
      # Check if a Test Analytics token is set
      return unless Buildkite::TestCollector.api_token

      metadata = fetch_metadata

      # return if metadata was not fetched successfully
      return if metadata.nil?

      # return if suite url is nil
      return if metadata['suite_url'].nil?

      scope = example.example.example_group.metadata[:full_description]
      name = example.example.description
      scope_name_digest = generate_scope_name_digest(scope, name)
      test_url = "#{metadata['suite_url']}/tests/#{scope_name_digest}"

      "\n  🔗 \x1b#{%(\x1b]1339;url=#{test_url};content="View test analytics"\x07)}\x1b[0m\n\n"
    end

    def fetch_metadata
      return unless Buildkite::TestCollector.api_token

      http = Buildkite::TestCollector::HTTPClient.new(Buildkite::TestCollector.url)
      response = http.metadata

      JSON.parse(response.body) if response.code == '200'
    rescue StandardError => e
      # We don't need to output anything here
    end
  end
end
