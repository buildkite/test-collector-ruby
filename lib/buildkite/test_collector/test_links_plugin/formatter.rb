# frozen_string_literal: true

require 'rspec/core/formatters/base_text_formatter'
require 'buildkite/test_collector/test_links_plugin/notifications'

module Buildkite::TestCollector::TestLinksPlugin
  class Formatter < RSpec::Core::Formatters::BaseTextFormatter
    RSpec::Core::Formatters.register self, :dump_failures

    def dump_failures(notification)
      return if notification.failure_notifications.empty?

      notifications = NotificationDecorator.new(notification)
      output.puts notifications.fully_formatted_failed_examples
    end
  end
end
