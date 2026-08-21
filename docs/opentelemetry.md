# OpenTelemetry export (experimental)

> **This feature is still under development and may change.**
> This first release is intended for suites that do not already configure
> OpenTelemetry. Existing OpenTelemetry setups may work, but are not yet
> supported or guaranteed to work.

Every RSpec example gets an OpenTelemetry `test.execution` root. When the suite
does not already configure OpenTelemetry, the collector can configure a provider
and export instrumented child spans showing what the test did and where its time
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

## Recommended setup: suites without OpenTelemetry

The collector configures a global SDK provider for child spans and installs the
applicable instrumentation registered when the suite starts. The private
provider still owns `test.execution`; instrumented spans use the
collector-created provider's normal sampling. The same forwarding filter
excludes setup, teardown, detached traces, and other spans outside an active
execution.

## Choosing instrumentation

Instrumentation selection applies only when the collector configures the global
provider. The collector includes the OpenTelemetry SDK and OTLP
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

To prevent the collector from installing registered instrumentation, pass an
empty list. Manually created spans under an execution are still forwarded:

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

## What gets sent

Spans go to Buildkite over OTLP, using the same `BUILDKITE_ANALYTICS_TOKEN` as
the rest of the collector. Sending them needs an agent OIDC token with the
`write_uploads` scope; a suite API token uploads test results as normal but its
spans are rejected.

OpenTelemetry's SDK owns batching, retries, and transport. `test.execution`
spans have a reserved, faster-draining queue and exporter. Forwarded children
use a separate queue and exporter, so a child flood or invalid child request
cannot displace or poison execution roots. When the suite finishes, both queues
share one 30-second flush budget, roots first. A hard exit or sustained endpoint
failure can still lose spans because the queues live in process memory.

## When something goes wrong

Export never fails a test. If root setup fails, the collector warns and the
normal test result upload continues without spans. If optional child setup or
attachment fails, the collector warns, cleans up that path, and continues
exporting roots. Suite shutdown gives the OpenTelemetry SDK a 30-second budget
to export buffered spans; the SDK's own retry backoff can run past it when the
endpoint keeps failing.

Export failures are reported through OpenTelemetry's own logger. The collector
also warns if its reserved root queue drops any `test.execution` spans; normal
child-span queue overflow is not logged by the OpenTelemetry SDK.
