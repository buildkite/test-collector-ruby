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

A failed test also sets the span's status to error. Why it failed stays on the
test's execution in Test Engine rather than on the span.

Two things worth knowing:

- An example skipped with `skip` produces no span at all. RSpec doesn't run its
  hooks, so there is nothing to time. `skipped` on a span means a `pending`
  example that failed as expected.
- The span's duration and the execution's duration are measured separately and
  can differ by a fraction of a millisecond.

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
the instrumentation this gem bundles, so you get spans for the databases, caches,
HTTP clients and background jobs your tests touch.

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
