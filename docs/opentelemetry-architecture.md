# OpenTelemetry architecture

The experimental RSpec integration is enabled with `otlp_endpoint:` or
`BUILDKITE_ANALYTICS_OTLP_ENDPOINT`. The normal Test Engine upload remains
authoritative; OpenTelemetry failures warn and fail open.

## Execution traces

Each RSpec example creates a parentless `test.execution` span. Instrumented work
runs with that span active and becomes its child. The span is finalized from
RSpec's reported result, after outer hooks have unwound.

Sampled spans and execution uploads share a UUIDv7:

```text
execution.external_id == test.execution["execution.externalId"]
```

Unsampled executions omit the upload ID so they never point to a missing span.
When Buildkite Agent `TRACEPARENT` and `TRACESTATE` are valid, the Agent context
is attached as a link rather than used as the execution span's parent.

## Provider ownership

The collector shares the application's tracer provider so auto-instrumented work
uses the execution span as its parent. It adds and shuts down only its own span
processor. Existing providers, resources, exporters, sampling, and lifecycle
remain application-owned.

Buildkite resource attributes are merged into copies sent through the Buildkite
exporter. They do not mutate the provider resource seen by customer exporters.
The collector installs all available Ruby instrumentations for this experiment;
a production integration should replace that with an explicit allowlist.

## Metadata

Buildkite pipeline, job, VCS, and run metadata comes directly from the
`BUILDKITE_*` environment. The run key is also sent as
`Buildkite-Test-Run-Key`, and `BUILDKITE_JOB_ID` as `Buildkite-Test-Job-ID`.

The execution root includes:

- test and suite names;
- pass, fail, or skipped status;
- normalized source path and line;
- RSpec name and version;
- the Test Engine case ID; and
- execution tags under `buildkite.test.execution.tag.*`.

Failure messages and stack traces remain on the Test Engine execution record.
The OpenTelemetry SDK owns context propagation, batching, retries, and OTLP
transport. Normal suite shutdown flushes the Buildkite processor; hard process
exits may lose buffered telemetry.
