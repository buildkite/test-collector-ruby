# frozen_string_literal: true

module Buildkite::TestCollector
  # Experimental OpenTelemetry span emission (TE-6490 PoC).
  #
  # When an OTLP endpoint is configured, we set up a global OpenTelemetry tracer
  # provider that exports spans over OTLP/HTTP. One parent span is opened per test
  # (see the RSpec around(:each) hook); OTel auto-instrumentation records whatever
  # the test touches as child spans. The root span carries the same external ID
  # as the test execution upload so the backend can join the two records.
  #
  # The opentelemetry-* gems are treated as soft dependencies: if they are not
  # installed, span export quietly disables itself and the collector behaves
  # exactly as before.
  #
  # PoC packaging shortcut: this PoC expects the host app to add the
  # opentelemetry-* gems to its own Gemfile. That is fine for the sample repo
  # but should NOT survive to shipping — we do not want to make customers add
  # several gems by hand. Productionization options (in preference order):
  #   1. Attach to the customer's EXISTING OpenTelemetry setup when one is
  #      present (many customers already run OTel), and do not re-instrument.
  #      In that case there are no extra gems for them to add at all.
  #   2. Otherwise, ship a companion gem (e.g. buildkite-test_collector-opentelemetry)
  #      that depends on the core collector plus the opentelemetry-* gems, so a
  #      customer opts in with a single Gemfile line. This keeps the core gem's
  #      Ruby >= 2.3 floor and its light dependency tree intact for everyone who
  #      does not use spans (Bundler has no real optional-dependency "extras").
  # Making the opentelemetry-* gems hard runtime deps of the core collector is
  # the option to avoid: it forces the whole OTel + instrumentation tree onto
  # every user and raises the Ruby floor to 3.0.
  module OTel
    EXECUTION_EXTERNAL_ID_ATTRIBUTE = "execution.externalId"

    class << self
      attr_reader :tracer

      def enabled?
        @enabled == true
      end

      # Set up the global tracer provider. Safe to call more than once (no-op
      # after the first successful configure).
      def configure!(endpoint:, api_token: nil)
        return if @enabled

        require "opentelemetry/sdk"
        require "opentelemetry/exporter/otlp"
        # PoC: pull in every instrumentation. TODO: bundle a curated set instead
        # of -all before shipping (see the use_all note below) — we do not want
        # all of them.
        require "opentelemetry/instrumentation/all"

        headers = {}
        headers["Authorization"] = "Token token=\"#{api_token}\"" if api_token

        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(
          endpoint: endpoint,
          headers: headers,
        )

        OpenTelemetry::SDK.configure do |c|
          c.service_name = "buildkite-test-collector-ruby"
          c.add_span_processor(
            OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter)
          )
          # Capture everything the test touches (HTTP, SQL, Redis, ...).
          #
          # PoC shortcut: use_all installs every available instrumentation, which
          # monkeypatches many libraries and can clash with a customer's own
          # instrumentation. For shipping we should instead detect an existing
          # tracer provider and NOT re-instrument (case 1 above), and otherwise
          # install a curated instrumentation set rather than use_all.
          c.use_all
        end

        @tracer = OpenTelemetry.tracer_provider.tracer(
          "buildkite-test-collector", Buildkite::TestCollector::VERSION
        )
        @enabled = true
      rescue LoadError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled (missing gem): #{e.message}"
        @enabled = false
      rescue StandardError => e
        warn "[buildkite-test_collector] OpenTelemetry span export disabled: #{e.class}: #{e.message}"
        @enabled = false
      end

      # Open one parent span for the given test execution. No-op (still yields)
      # when OTel is not enabled.
      def in_test_span(name:, external_id: nil, attributes: {})
        return yield unless enabled?

        span_attributes = { EXECUTION_EXTERNAL_ID_ATTRIBUTE => external_id }.merge(attributes).compact
        @tracer.in_span(name, attributes: span_attributes, kind: :internal) do |_span|
          yield
        end
      end

      def force_flush
        return unless enabled?

        OpenTelemetry.tracer_provider.force_flush
      end

      def shutdown
        return unless enabled?

        OpenTelemetry.tracer_provider.shutdown
      ensure
        @enabled = false
      end
    end
  end
end
