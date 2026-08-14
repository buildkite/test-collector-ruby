# OpenTelemetry export (experimental)

> **This is still under development and everything here may change.**

Every RSpec example becomes a small OpenTelemetry trace. The root span is always
created by the collector, and optional instrumentation can show the queries,
HTTP calls, and other work beneath it. The traces are sent to Buildkite and shown
against the test's execution.

It is off by default. See the [README](../README.md#opentelemetry-export-experimental)
for how to turn it on.

## Set up OpenTelemetry

Choose the setup that matches your test suite: either keep using an existing
OpenTelemetry setup, or let the collector set one up for you. Both options send
one trace per test execution to Buildkite.

Instrumentation patches application libraries globally and can conflict with
another APM, profiler, HTTP adapter, or monkey patch in the host process. The
collector therefore does not bundle or require instrumentation gems. You choose
which ones to add and load.

The examples below use these dependencies to add Net::HTTP child spans:

```ruby
# Gemfile
group :test do
  gem 'buildkite-test_collector'
  gem 'opentelemetry-exporter-otlp', '~> 0.34'
  gem 'opentelemetry-instrumentation-net_http'
  gem 'opentelemetry-sdk', '~> 1.13'
end
```

### If your suite already uses OpenTelemetry

Your suite already has SDK and instrumentation setup like this. Keep it as-is:

```ruby
# spec/spec_helper.rb
# Existing OpenTelemetry setup
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'opentelemetry/instrumentation/net_http'

OpenTelemetry::SDK.configure do |config|
  config.use 'OpenTelemetry::Instrumentation::Net::HTTP'
end
```

Add the collector configuration after that existing setup:

```ruby
# spec/spec_helper.rb
# New Buildkite Test Engine setup
require 'buildkite/test_collector'

Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
)
```

- The collector leaves your OpenTelemetry settings and instrumentation alone.
- Work already instrumented by your suite appears beneath `test.execution` in
  Buildkite.
- The collector generates test trace IDs independently of the test framework's
  random seed, preventing deterministic collisions between processes.
- Your existing exporter continues to receive spans created by your suite. It
  does not receive the collector's `test.execution` span, which is sent only to
  Buildkite.
- `otel_instrumentations` has no effect because your suite owns instrumentation.

### If your suite does not use OpenTelemetry

Load the instrumentation gems you want and let the collector handle the rest.
Do not call `OpenTelemetry::SDK.configure` yourself:

```ruby
# spec/spec_helper.rb
require 'opentelemetry-instrumentation-net_http'
require 'buildkite/test_collector'

Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
)
```

The collector installs the loaded Net::HTTP instrumentation and sends
`test.execution` and its child spans to Buildkite.

Choose how much to instrument:

- **Root spans only.** Do not load an instrumentation gem, or pass
  `otel_instrumentations: []` to suppress instrumentation loaded elsewhere.
- **Child spans.** Load each individual instrumentation gem you want. By default,
  the collector installs every loaded instrumentation. If several are loaded,
  use `otel_instrumentations` to select a subset by canonical name:

```ruby
Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: ['OpenTelemetry::Instrumentation::Net::HTTP'],
)
```

Other canonical names include `OpenTelemetry::Instrumentation::PG` and
`OpenTelemetry::Instrumentation::Redis`. An unregistered, unavailable,
incompatible, or failed entry emits a warning and does not prevent root-span
export.

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

When the collector handles setup, instrumentation installation is also
fail-open. Unknown names, missing library dependencies, incompatibilities, and
installation errors warn and leave root-span export running. The collector does
not try to detect other APM patches, so load only instrumentation that is safe
for your test process or use `otel_instrumentations` to restrict the registered
set.

Export problems are reported through OpenTelemetry's own logger, so look there
for the reason if spans aren't arriving.
