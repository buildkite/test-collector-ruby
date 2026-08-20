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
all applicable instrumentation registered when the suite starts, as described
below.

## Choosing instrumentation

Instrumentation selection applies only when the collector creates the
OpenTelemetry provider. The collector includes the OpenTelemetry SDK and OTLP
exporter, but no instrumentation gems. Add the instrumentation you want to your
bundle and require it explicitly:

```ruby
# Gemfile
group :test do
  gem "opentelemetry-instrumentation-pg", require: false
  gem "opentelemetry-instrumentation-redis", require: false
end
```

```ruby
# spec/spec_helper.rb
require "opentelemetry-instrumentation-pg"
require "opentelemetry-instrumentation-redis"
require "buildkite/test_collector"

Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
)
```

A Gemfile entry makes the gem available but does not always load it. Some
applications call `Bundler.require` and auto-require their gems, but that is
host-dependent and can be disabled with `require: false`. Explicitly requiring
each instrumentation is the recommended setup.

Requiring an instrumentation gem registers its definition; it does not install
the instrumentation immediately. The collector defers OpenTelemetry setup until
RSpec's `before(:suite)` hooks and asks the SDK to install all registered
instrumentation. The SDK skips instrumentation whose target library is absent
or incompatible and reports individual installation failures without stopping
the remaining installations.

To export root `test.execution` spans without installing any registered
instrumentation, pass an empty list:

```ruby
Buildkite::TestCollector.configure(
  hook: :rspec,
  otel_enabled: true,
  otel_instrumentations: [],
)
```

For this release, omitting `otel_instrumentations` and setting it to `[]` are the
only supported choices. Any other value is reserved for a future release and
disables span export with a warning, in every path. The collector does not
inspect instrumentation patches, so compatibility between customer-selected
instrumentation and other APM or test-library patches remains the customer's
responsibility.

When the suite already owns OpenTelemetry, a supported `otel_instrumentations`
selection has no effect: the collector installs nothing and uses the suite's
instrumentation unchanged. A warning reports an `[]` selection that was ignored.

## What gets sent

Spans go to Buildkite over OTLP, using the same `BUILDKITE_ANALYTICS_TOKEN` as
the rest of the collector. Sending them needs an agent OIDC token with the
`write_uploads` scope; a suite API token uploads test results as normal but its
spans are rejected.

OpenTelemetry's SDK owns the batching, retries and transport. `test.execution`
spans have a reserved, faster-draining queue and are exported separately from
automatically instrumented spans, so a flood or invalid batch of child spans
cannot displace the execution roots. When the suite finishes, both queues share
one 30-second flush budget passed to the SDK, roots first. A hard exit or a
sustained endpoint failure can still lose spans because the queues live in
process memory.

## When something goes wrong

Export never fails a test. If the OpenTelemetry gems are missing, setup fails, or
spans can't be delivered, the collector warns and carries on, and your test
results upload as they always have. Suite shutdown gives the OpenTelemetry SDK a
30-second budget to export buffered spans; the SDK's own retry backoff can run
past it when the endpoint keeps failing.

Export failures are reported through OpenTelemetry's own logger. The collector
also warns if its reserved root queue drops any `test.execution` spans; normal
child-span queue overflow is not logged by the OpenTelemetry SDK.
