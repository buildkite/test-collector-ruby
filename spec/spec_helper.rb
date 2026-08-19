# frozen_string_literal: true

require "buildkite/test_collector"
require "active_support/notifications"
require "cucumber"

Dir["spec/support/**/*.rb"].each { |f| require File.expand_path(f) }

# Set up the various hooks that the collector uses.
#
# This provides some coverage for the code in
# lib/buildkite/test_collector/library_hooks/rspec.rb which is otherwise
# currently untested. At present this suite is not connected to Buildkite
# Test Engine so these hooks will all be noops. However this does give us
# some regression testing for the code that sets up the hooks themselves.
Buildkite::TestCollector.configure(hook: :rspec)

RSpec.configure do |config|
  # The OpenTelemetry gems need Ruby 3.3, so their specs are written for it and
  # older Rubies must not even parse them.
  unless Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')
    config.exclude_pattern = "{**/otel_spec.rb,**/otel/**/*_spec.rb,**/correlation_spec.rb}"
  end

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include FakeEnvHelpers
end
