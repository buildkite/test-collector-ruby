# OpenTelemetry architecture

The RSpec integration is opt-in, with `otel_enabled:`. Everything here fails
open: configuration and delivery failures warn, and the normal Test Engine
upload stays authoritative.

Spans go to Buildkite's OTLP endpoint, which authenticates with the same token as
the upload API. That endpoint only accepts agent OIDC tokens, so a suite API
token gets a 401 for spans while its executions still upload normally.

## Execution traces

Each RSpec example creates a parentless `test.execution` span, and instrumented
work runs beneath it. The span says which test it was and how it went:

| Attribute | Value |
| --- | --- |
| `test.case.name` | the example's full description |
| `test.suite.name` | the example group |
| `code.file.path` | the same path the execution upload reports |
| `code.line.number` | the example, or the call site for a shared example |
| `test.case.result.status` | `pass`, `fail` or `skipped` |

A failure also sets the span status to error. OpenTelemetry defines `pass` and
`fail`, which we use where they apply, and allows a custom value where none does,
which is where `skipped` comes from. Failure details stay on the execution record.

RSpec settles an example's result after our `around` hook unwinds, so the hook
derives the result from the exception and pending state in the same way RSpec
does. It finishes the span before returning, so its duration covers the example
rather than the reporting that follows.

The span's trace ID goes on the execution upload, so the two can be joined once
both have been ingested:

```text
execution.trace_id == test.execution.trace_id
```

Child spans inherit that trace ID through normal context propagation, so one
query returns an execution's whole trace. Nothing is stamped on a child span.
The trace ID is the one the SDK assigned when it started the parentless root,
not an ID we generate.

This holds only while `test.execution` stays parentless, so one trace maps to
exactly one execution. The span is never nested under the Agent's build or job
trace for that reason.

## Provider ownership

The collector shares the application's tracer provider but owns only its span
processor. Existing resources, exporters, sampling, and lifecycle remain
application-owned, and our processor goes quiet once shut down, since a provider
has no way to drop one.

Instrumentation depends on who owns the setup. A suite already running
OpenTelemetry keeps its own: its spans reach us through the shared provider, and
installing ours would push spans it never asked for into its own exporters. When
there is no setup to share, we create the provider and install everything
available. Narrowing that to a hand picked set is a decision for once dogfooding
shows which spans are worth the noise.

Sampling stays with the application's own tracer provider. We don't sample here,
and an unsampled execution still reports its trace ID.

## Metadata

The run key is sent as the `Buildkite-Test-Run-Key` header and the receiver
derives the canonical suite-scoped run from it. Job identity comes from the
authenticated token, not from us. Nothing else is added to a span: the build,
pipeline, and VCS metadata already hangs off those records server-side.

The OpenTelemetry SDK owns propagation, batching, retries, and transport. Suite
shutdown flushes the Buildkite processor; hard exits may lose buffered spans.
