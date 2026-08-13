# frozen_string_literal: true

require_relative "lib/buildkite/test_collector/version"

Gem::Specification.new do |spec|
  spec.name          = "buildkite-test_collector"
  spec.version       = Buildkite::TestCollector::VERSION
  spec.authors       = ["Buildkite"]
  spec.email         = ["support+analytics@buildkite.com"]

  spec.summary       = "Track test executions and report to Buildkite Test Engine"
  spec.homepage      = "https://github.com/buildkite/test-collector-ruby"
  spec.license       = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/buildkite/test-collector-ruby"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{\A(?:test|spec|features)/}) }
  end
  spec.require_paths = ["lib"]

  spec.required_ruby_version = Gem::Requirement.new(">= 2.3.0")

  spec.add_dependency "concurrent-ruby"

  # OpenTelemetry export needs Ruby 3.3, so these ship as dependencies only for
  # the Rubies that can run them. The collector requires them lazily and fails
  # open without them, so older Rubies keep working with export unavailable.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')
    spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.34"
    spec.add_dependency "opentelemetry-instrumentation-all", "~> 0.94"
    spec.add_dependency "opentelemetry-sdk", "~> 1.13"
  end

  spec.add_development_dependency "activesupport", ">= 4.2"
  spec.add_development_dependency "ostruct"
  spec.add_development_dependency "rspec-core", '~> 3.10'
  spec.add_development_dependency "rspec-expectations", '~> 3.10'

  # When running the legacy CI builds against versions of Ruby pre 2.7 we cannot include cucumber 9 as it's not supported.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('2.7')
    spec.add_development_dependency "cucumber", '~> 9.0'
  end
end
