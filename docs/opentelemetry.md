# OpenTelemetry export (experimental)

> **This is still under development and everything here may change.**

This page describes `otel_enabled`, where spans are exported *alongside* the
normal JSON upload and linked to it by trace ID. There is also an OTLP-only
mode (`otel_only`) where the span *is* the submission: it carries the full
execution details (`buildkite.execution.via=otlp`, result, failure reason and
backtrace, tags) and Buildkite synthesizes the execution from it server-side,
with nothing sent to `/v1/uploads`. In that mode the run's details (run key,
branch, commit, and any `tags:` you configure) travel as OpenTelemetry resource
attributes on the spans the collector exports. See the
[README](../README.md#otlp-only-submission-experimental) for how to turn it on,
and [OTLP-only attributes](#otlp-only-attributes) below for what's sent.

Every RSpec example gets an OpenTelemetry `test.execution` root. When the suite
already uses OpenTelemetry, its sampled child spans show what the test did and
where its time went. The traces are sent to Buildkite and shown against the
test's execution.

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

Each `tags:` entry passed to `configure` is attached to the root as a
`buildkite.tag.<key>` resource attribute. Per-execution tags use the same prefix
as span attributes.

| Attribute | Value |
| --- | --- |
| `test.case.name` | the example's full description |
| `test.suite.name` | the example group |
| `code.file.path` | the file the test is in |
| `code.line.number` | the line, or the call site for a shared example |
| `test.case.result.status` | `pass`, `fail` or `skipped` |
| `buildkite.test.execution.external_id` | the ID of the matching Test Engine execution |
| `buildkite.tag.<key>` | each `tag_execution` tag |

A failed test also sets the span's status to error. Why it failed stays on the
test's execution in Test Engine rather than on the span.

Two things worth knowing:

- An example skipped with `skip` produces no span at all. RSpec doesn't run its
  hooks, so there is nothing to time. `skipped` on a span means a `pending`
  example that failed as expected.
- The execution's duration is whatever the span timed, so the two always agree.
  With the export off, the collector times the example itself as it always has.
- The result is RSpec's final verdict, read after every `around` hook has
  unwound: an `around` hook that raises after the example ran counts as a
  failure, and an example a hook marks `pending` before deliberately raising
  stays skipped.

## OTLP-only attributes

With `otel_only`, the span is the submission, so it carries more. Buildkite
attributes are flat (`buildkite.run_key`, `buildkite.build_id`, ...), matching
the agent's own OpenTelemetry attributes; everything else follows OpenTelemetry
semantic conventions.

Run-level details travel once, as resource attributes on every span:

| Resource attribute | Value | Execution field |
| --- | --- | --- |
| `buildkite.run_key` | the run key (required) | run key |
| `buildkite.run_url` | the build URL | URL |
| `vcs.ref.head.name` | the branch (or tag) name | branch |
| `vcs.ref.head.revision` | the commit SHA | commit |
| `vcs.ref.head.type` | `branch` or `tag` | — |
| `buildkite.build_number` | the build number | number |
| `buildkite.build_id` | the build's UUID | build ID |
| `buildkite.job_id` | the job's UUID | job ID |
| `buildkite.step_id` | the step's UUID | step ID |
| `buildkite.message` | the commit message | message |
| `buildkite.collector.name` | this gem's name | collector |
| `buildkite.collector.version` | this gem's version | version |
| `buildkite.tag.<key>` | each `tags:` entry from `configure` | run tag `<key>` |

The resource also names the suite for any other OpenTelemetry backend looking
at the same spans: `service.name` (the suite slug), `service.namespace` (the
organization slug), `service.instance.id` (the job UUID), and
`buildkite.test.framework.name`/`.version`. Buildkite doesn't use these.

Each test's span carries the execution itself:

| Span attribute | Value | Execution field |
| --- | --- | --- |
| `buildkite.execution.via` | `otlp` — opts this span in to synthesis | — |
| `buildkite.test.scope` | the example group | scope |
| `buildkite.test.name` | the example's description | name |
| `test.suite.name` | the example group | — |
| `test.case.name` | the example's full description | — |
| `code.file.path` | the file the test is in | file name, location |
| `code.line.number` | the line number | location |
| `test.case.result.status` | `pass`, `fail`, `skipped` | result |
| `buildkite.tag.<key>` | each `tag_execution` tag | execution tag `<key>` |

A failure travels in OpenTelemetry's native shapes rather than as attributes:
the failure summary is the span's error status description, and each individual
failure is a semconv `exception` event (`exception.message`,
`exception.stacktrace`). The server maps these back to the execution's failure
reason and expanded failure detail.

## Finding a test's trace

The trace's ID is sent with the test's execution, so Buildkite can show you the
two together. Child spans share that ID through normal context propagation, so
one trace holds everything the test did.

## If you already use OpenTelemetry

We fit around your setup rather than replacing it:

- **Execution roots use a private provider.** Its sampler is AlwaysOn, so your
  sampling policy cannot remove `test.execution` spans.
- **Your provider remains yours.** We attach a forwarding span processor, but do
  not replace the provider or change its resource, sampler, exporters, or
  lifecycle.
- **Your instrumentation is left alone.** The collector neither installs nor
  configures instrumentation.
- **Only execution children are forwarded.** A span must start under an active
  Buildkite execution context. Suite setup, teardown, detached traces, and other
  ambient spans are not sent to Buildkite.
- **Your exporters see only your spans.** The private execution root goes only to
  Buildkite. Suite children retain its trace ID and parent span ID through normal
  OpenTelemetry context propagation. Because your backend does not receive that
  root, it may display these test traces as partial or headless.
- **Child sampling is yours.** `AlwaysOff` records no children. A parent-based
  sampler commonly keeps children because the private root is sampled. This can
  increase the span volume sent to your exporters during tests, even when its
  root policy normally samples traces down. That is the suite's configured
  parent-based behavior, not a Buildkite override. Only children marked as
  sampled are sent to Buildkite; record-only spans are not exported.

Set up the suite's provider and instrumentation before RSpec runs
`before(:suite)` hooks. Context-propagated asynchronous work is included even if
it finishes after the execution block; work that does not propagate the context
is excluded.

## Without suite OpenTelemetry

The collector configures a global SDK provider for child spans and installs the
applicable instrumentation registered when the suite starts. The private
provider still owns `test.execution`; instrumented spans use the
collector-created provider's normal sampling. The same forwarding filter
excludes setup, teardown, detached traces, and other spans outside an active
execution.

## Choosing instrumentation

Instrumentation selection applies only when the collector configures the global
provider, and works the same with `otel_enabled` and `otel_only`.
The collector includes the OpenTelemetry SDK and OTLP
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

When the suite already owns OpenTelemetry, a supported `otel_instrumentations`
selection has no effect: the collector installs nothing and uses the suite's
instrumentation unchanged. A warning reports an `[]` selection that was ignored.

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

One process reports one run. Export survives repeated suite runs in the same
process (warm workers), and a refreshed token is picked up when the collector
is reconfigured, but run identity is fixed when export starts: reconfiguring
with a different run key warns and keeps attributing results to the original
run. Reporting a new run requires a new process.

## When something goes wrong

Export never fails a test. If root setup fails, the collector warns and the
normal test result upload continues without spans. If optional child setup or
attachment fails, the collector warns, cleans up that path, and continues
exporting roots. The suite-end flush and the process-exit shutdown each give
the OpenTelemetry SDK a 30-second budget to export buffered spans; the SDK's
own retry backoff can run past it when the endpoint keeps failing.

Export failures are reported through OpenTelemetry's own logger. The collector
also warns if its reserved root queue drops any `test.execution` spans; normal
child-span queue overflow is not logged by the OpenTelemetry SDK.
