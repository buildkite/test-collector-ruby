# frozen_string_literal: true

# OTLP is the only upload method: no JSON upload, no legacy tracer, and no
# monkeypatching of Net::HTTP or Object. The gem's whole job is one
# OpenTelemetry span per test execution. This is deliberately a separate hook
# file from rspec.rb so that the standard code path stays untouched.

require "rspec/core"
require "rspec/expectations"

require_relative "../rspec_plugin/otel_only"

Buildkite::TestCollector::RSpecPlugin::OTelOnly.install!
