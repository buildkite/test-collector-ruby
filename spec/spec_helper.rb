# frozen_string_literal: true

require "buildkite/test_collector"
require "active_support/notifications"

if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7')
  require "cucumber"
end

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
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include FakeEnvHelpers
end
