# OpenTelemetry export (experimental)

> **This is still under development and everything here may change.**

Every RSpec example becomes a small OpenTelemetry trace. The root span is always
created by the collector, and optional instrumentation can show the queries,
HTTP calls, and other work beneath it. The traces are sent to Buildkite and shown
against the test's execution.

It is off by default. See the [README](../README.md#opentelemetry-export-experimental)
for how to turn it on.

## Choose what gets instrumented

Instrumentation patches application libraries globally and can conflict with
another APM, profiler, HTTP adapter, or monkey patch in the host process. The
collector therefore does not bundle or require any instrumentation gems. By
default it installs all individual instrumentation gems the suite has already
loaded, treating each explicit `require` as the consumer's choice to enable it.

The collector supports two provider setups:

1. **The host already has OpenTelemetry configured.** The collector leaves the
   host's provider settings and instrumentation unchanged. It creates each
   execution root with its own provider and forwards the host's instrumented
   child spans to Buildkite. `otel_instrumentations` is ignored because the host
   application owns instrumentation.
2. **The host does not have OpenTelemetry configured.** The collector configures
   the global provider and installs instrumentation from gems the suite has
   loaded.

In the second setup, choose how much to instrument:

- **Root spans only.** Add `opentelemetry-sdk` and
  `opentelemetry-exporter-otlp`, then enable export as shown in the README. Do
  not load an instrumentation gem, or pass `otel_instrumentations: []` to
  suppress instrumentation already loaded elsewhere.
- **Child spans.** Add and require each individual instrumentation gem you want.
  The collector installs every instrumentation registered by those gems. You
  can optionally restrict installation with `otel_instrumentations`.

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
)
```

If several instrumentation gems are loaded but you only want a subset, provide
their canonical names:

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

## If you already use OpenTelemetry

We fit in around your setup rather than replacing it:

- **Execution roots are collector-owned.** A private provider creates
  `test.execution` with IDs from the operating system's random source, so test
  framework PRNG seeds cannot make separate processes collide. It uses the
  host provider's resource attributes when available.
- **Your tracer provider stays in charge of child spans.** We add a forwarding
  span processor to it and do not change its ID generator, resource, exporters,
  sampler, or lifecycle. The forwarding processor cannot shut down the
  collector's exporter, and collector shutdown does not affect your processors.
- **Your instrumentation is left alone.** Its spans already reach us through the
  forwarding processor, so we don't install any of our own. That also means we
  never add spans you didn't ask for to your own exporters.
- **Your exporters do not see `test.execution` spans.** Those roots belong only
  to the collector's private provider. Your exporters still see child spans
  created by your provider, and those children inherit the root trace and parent
  IDs through normal OpenTelemetry context propagation.
- **Sampling stays independent.** The private provider decides whether to sample
  execution roots, while your sampler decides whether to keep instrumented child
  spans.
- **We stop when the suite does.** After the run, our processor goes quiet and
  yours keeps working.

If you don't have OpenTelemetry set up, we create a tracer provider and export
the root span. We install every individual instrumentation gem already loaded by
the suite, or only the entries in `otel_instrumentations` when provided.

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

Instrumentation installation is also fail-open during setup. Unknown names,
missing library dependencies, incompatibilities, and installation errors warn
and leave root-span export running. The collector does not try to detect other
APM patches, so consumers should load only instrumentation that is safe for their
host process or use `otel_instrumentations` to restrict the registered set.

Export problems are reported through OpenTelemetry's own logger, so look there
for the reason if spans aren't arriving.
