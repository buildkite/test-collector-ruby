# OpenTelemetry architecture

The experimental RSpec integration is enabled by configuring OIDC
authentication (below), which exports to the default endpoint
`https://test-otlp.buildkite.com/v1/traces`. `otlp_endpoint:` or
`BUILDKITE_ANALYTICS_OTLP_ENDPOINT` overrides the endpoint, for example
`http://test-otlp.buildkite.localhost/v1/traces` in local development.
OpenTelemetry failures warn and fail open; the normal Test Engine upload
remains authoritative.

## Authentication

`POST /v1/traces` accepts only agent OIDC tokens with a suite-URL audience and
the `write_uploads` scope; suite API tokens are rejected. The collector sends
`Authorization: Token <jwt>` using, in order of preference:

1. `BUILDKITE_ANALYTICS_OTLP_OIDC_TOKEN` — a pre-fetched OIDC token.
2. `BUILDKITE_ANALYTICS_OTLP_OIDC_AUDIENCE` — the suite URL, e.g.
   `https://buildkite.com/organizations/{org}/analytics/suites/{suite}`. The
   collector runs `buildkite-agent oidc request-token --audience <audience>`
   at configure time.

If neither is set, span export is disabled with a warning.

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

Resource metadata comes from `BUILDKITE_*`. The run key is also sent as the
`Buildkite-Test-Run-Key` header; the job ID is derived server-side from the
OIDC token. Execution spans
include test identity, result, source location, RSpec version, and execution tags.
Failure details remain on the Test Engine execution record.

The OpenTelemetry SDK owns propagation, batching, retries, and transport. Suite
shutdown flushes the Buildkite processor; hard exits may lose buffered spans.
