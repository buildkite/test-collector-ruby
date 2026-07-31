# OpenTelemetry architecture

The experimental RSpec integration is enabled with `otlp_endpoint:` or
`BUILDKITE_ANALYTICS_OTLP_ENDPOINT`. OpenTelemetry failures warn and fail open;
the normal Test Engine upload remains authoritative.

## Execution traces

Each RSpec example creates a parentless `test.execution` span. Instrumented work
runs beneath it, and the span is finalized from RSpec's reported result after
outer hooks unwind.

Sampled spans and execution uploads share an ID:

```text
execution.external_id == test.execution["execution.externalId"]
```

Unsampled executions omit it. Valid Buildkite Agent `TRACEPARENT` and
`TRACESTATE` are attached as a link, never as the execution span's parent.

## Provider ownership

The collector shares the application's tracer provider but owns only its span
processor. Existing resources, exporters, sampling, and lifecycle remain
application-owned. Buildkite resource attributes are applied only to copies sent
through the Buildkite exporter.

This experiment installs all available Ruby instrumentations. A production
integration should use an explicit allowlist.

## Metadata

Resource metadata comes from `BUILDKITE_*`. The run and job IDs are also sent as
`Buildkite-Test-Run-Key` and `Buildkite-Test-Job-ID` headers. Execution spans
include test identity, result, source location, RSpec version, and execution tags.
Failure details remain on the Test Engine execution record.

The OpenTelemetry SDK owns propagation, batching, retries, and transport. Suite
shutdown flushes the Buildkite processor; hard exits may lose buffered spans.
