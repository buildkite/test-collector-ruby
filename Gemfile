# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in the gemspec
gemspec

gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

# OpenTelemetry requires Ruby 3.3. It is an optional, consumer-managed
# integration rather than a runtime dependency of the collector.
if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3")
  gem "opentelemetry-exporter-otlp", "~> 0.34"
  gem "opentelemetry-sdk", "~> 1.13"
end
