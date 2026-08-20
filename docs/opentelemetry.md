# OpenTelemetry export (experimental)

> **This is still under development and everything here may change.**

Every RSpec example becomes a small OpenTelemetry trace, so you can see what a
test actually did: the queries it ran, the HTTP calls it made, and where its time
went. The traces are sent to Buildkite and shown against the test's execution.

It is off by default. See the [README](../README.md#opentelemetry-export-experimental)
for how to turn it on.

## What a trace looks like

Each example gets a `test.execution` span of its own, with the instrumented work
it did underneath:

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

If you don't have OpenTelemetry set up, we create a tracer provider and install
the applicable curated SQL instrumentation, as described below.

## Choosing instrumentation

Instrumentation selection applies only when the collector creates the
OpenTelemetry provider. The default set is `pg`, `mysql2`, and `trilogy`; each is
installed only when its target library is already loaded. You do not need to set
`otel_instrumentations` to use these defaults: omit the option completely, or
set it to `nil`.

```ruby
# Applicable curated defaults; no otel_instrumentations option needed
Buildkite::TestCollector.configure(hook: :rspec, otel_enabled: true)

# Applicable curated defaults, explicitly
Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: [:defaults],
)

# Root test.execution spans only
Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: [],
)

# An exact stable subset of bundled instrumentation
Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: [:pg],
)
```

`:defaults` expands to the collector's current default set, which may change
when the collector is upgraded. Without `:defaults`, the list is exact.

The collector exposes symbols for the instrumentation it bundles. For other
instrumentation, add its gem to your bundle, require it before RSpec's
`before(:suite)` hooks run, and pass its registered OpenTelemetry name:

```ruby
require "opentelemetry-instrumentation-redis"

Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: [
    :defaults,
    "OpenTelemetry::Instrumentation::Redis",
  ],
)
```

The collector does not require target application libraries such as `pg` or
`redis`. Immediately before installing a bundled default, it checks the target
for an existing foreign prepend, such as a Datadog, New Relic, or Sentry patch.
The collector cannot determine whether two arbitrary prepends are compatible,
so it conservatively skips that default whenever it finds one. The warning names
the module and target that caused the skip; other instrumentation and the root
`test.execution` spans continue normally.

Disabling another tracer does not necessarily remove patches it already
installed. If its module remains prepended to the target, the collector still
skips the corresponding default. Customer-supplied instrumentation is installed
as explicitly requested without this guard, so its compatibility with other
patches is the customer's responsibility. Unknown, unavailable, incompatible,
or failed entries are reported and skipped.

When the suite already owns OpenTelemetry, `otel_instrumentations` has no effect:
the collector installs nothing and uses the suite's instrumentation unchanged.

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

Export problems are reported through OpenTelemetry's own logger, so look there
for the reason if spans aren't arriving.
