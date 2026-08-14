# OpenTelemetry export (experimental)

> **This is still under development and everything here may change.**

Every RSpec example becomes a small OpenTelemetry trace. The root span is always
created by the collector, and optional instrumentation can show the queries,
HTTP calls, and other work beneath it. The traces are sent to Buildkite and shown
against the test's execution.

It is off by default. See the [README](../README.md#opentelemetry-export-experimental)
for how to turn it on.

## Choose what gets instrumented

The safe default is a root `test.execution` span with no automatically installed
library instrumentation. Instrumentation patches application libraries globally,
so installing everything can conflict with another APM, profiler, HTTP adapter,
or monkey patch in the host process.

The collector supports three setups:

1. **Root spans only.** Add `opentelemetry-sdk` and
   `opentelemetry-exporter-otlp`, then enable export as shown in the README. No
   instrumentation gem is needed.
2. **Explicit child spans.** Add and require each instrumentation gem, then pass
   its canonical OpenTelemetry name in `otel_instrumentations`.
3. **An existing OpenTelemetry setup.** The collector uses the host's provider
   and instrumentation unchanged. In this mode `otel_instrumentations` is
   ignored because the host application owns instrumentation.

For example, to add Net::HTTP child spans:

```ruby
# Gemfile
group :test do
  gem 'buildkite-test_collector'
  gem 'opentelemetry-exporter-otlp', '~> 0.34'
  gem 'opentelemetry-instrumentation-net_http'
  gem 'opentelemetry-sdk', '~> 1.13'
end
```

```ruby
# spec/spec_helper.rb
require 'opentelemetry-instrumentation-net_http'
require 'buildkite/test_collector'

Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: ['OpenTelemetry::Instrumentation::Net::HTTP'],
)
```

Use canonical names from the instrumentation gems, such as
`OpenTelemetry::Instrumentation::PG` or
`OpenTelemetry::Instrumentation::Redis`. The collector installs only names in
the allowlist. An unregistered, unavailable, incompatible, or failed entry emits
a warning and does not prevent root-span export.

The OpenTelemetry gems require Ruby 3.3 or newer. They are deliberately not
runtime dependencies of `buildkite-test_collector`, whose supported Ruby range
starts at 2.3. Keeping them in the host Gemfile also lets the host choose versions
compatible with its existing observability libraries.

## What a trace looks like

Each example gets a `test.execution` span of its own, with the instrumented work
it did underneath when child-span instrumentation is selected:

```text
test.execution  "Buildkite::Pipeline creates a build"   12.4ms
├── GET         api.example.com                          8.1ms
└── SELECT      pipelines                                1.2ms
```

One example is one trace. The span is never nested under anything else, so a
trace always belongs to exactly one test. On Buildkite Agent v3.110 or newer,
the root span links to the Agent's propagated job trace when tracing is enabled,
letting you navigate between them without combining every test into one trace.

## What's on the span

| Attribute | Value |
| --- | --- |
| `test.case.name` | the example's full description |
| `test.suite.name` | the example group |
| `code.file.path` | the file the test is in |
| `code.line.number` | the line, or the call site for a shared example |
| `test.case.result.status` | `pass`, `fail` or `skipped` |
| `buildkite.test.execution.external_id` | the ID of the matching Test Engine execution |

A failed test also sets the span's status to error. Why it failed stays on the
test's execution in Test Engine rather than on the span.

Two things worth knowing:

- An example skipped with `skip` produces no span at all. RSpec doesn't run its
  hooks, so there is nothing to time. `skipped` on a span means a `pending`
  example that failed as expected.
- The execution's duration is whatever the span timed, so the two always agree.
  With the export off, the collector times the example itself as it always has.

## Finding a test's trace

The trace's ID is sent with the test's execution, so Buildkite can show you the
two together. Child spans share that ID through normal context propagation, so
one trace holds everything the test did.

## If you already use OpenTelemetry

We fit in around your setup rather than replacing it:

- **Your tracer provider is used as-is.** We add a span processor to it and
  nothing else. Your resource, exporters, sampler and lifecycle are untouched.
- **Your instrumentation is left alone.** Its spans already reach us through the
  provider we share, so we don't install any of our own. That also means we never
  add spans you didn't ask for to your own exporters.
- **Your exporters will see `test.execution` spans.** A provider gives every span
  to all of its processors, so these spans arrive in your backend too.
- **Sampling is yours.** We don't sample, we use whatever your provider decides.
- **We stop when the suite does.** After the run, our processor goes quiet and
  yours keeps working.

If you don't have OpenTelemetry set up, we create a tracer provider and export
the root span. We install only the instrumentation explicitly selected with
`otel_instrumentations`; the default list is empty.

## What gets sent

Spans go to Buildkite over OTLP, using the same `BUILDKITE_ANALYTICS_TOKEN` as
the rest of the collector. Sending them needs an agent OIDC token with the
`write_uploads` scope; a suite API token uploads test results as normal but its
spans are rejected.

OpenTelemetry's SDK owns the batching, retries and transport. Buffered spans are
flushed when the suite finishes, so a hard exit can lose the last few.

## When something goes wrong

Export never fails a test or holds up your results. If the OpenTelemetry gems are
missing, or setup fails, or spans can't be delivered, the collector warns and
carries on, and your test results upload as they always have.

Instrumentation selection is also fail-open during setup. Unknown names, missing
library dependencies, incompatibilities, and installation errors warn and leave
root-span export running. The collector does not try to detect other APM patches;
the empty default avoids modifying the host process in the first place.

Export problems are reported through OpenTelemetry's own logger, so look there
for the reason if spans aren't arriving.
