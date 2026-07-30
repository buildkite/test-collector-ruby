# OpenTelemetry architecture

## Status and scope

This experimental integration exports RSpec test executions and the work they
perform as OpenTelemetry traces. It is opt-in through `otlp_endpoint:` or
`BUILDKITE_ANALYTICS_OTLP_ENDPOINT` and requires Ruby 3.3 or newer.

The existing Test Engine execution upload remains authoritative and independent.
OpenTelemetry failures are fail-open: configuration failures warn and disable
span export, while lifecycle and delivery failures warn and may drop telemetry.
They never fail the test or prevent the normal execution upload.

## Data flow

```text
┌────────────────────────── Ruby test process ──────────────────────────┐
│                                                                       │
│  RSpec example                                                        │
│    └── test.execution                                                 │
│          ├── execution.externalId = execution upload external_id      │
│          └── HTTP, SQL, Redis, ... auto-instrumented child spans      │
│                                                                       │
│  Execution uploader ───────────────────────▶ Test Engine upload API   │
│                                                                       │
│  OTel BatchSpanProcessor                                              │
│    └── Buildkite OTLP exporter                                        │
│          ├── Buildkite-Test-Run-Key: <raw run key>                    │
│          └── buildkite.test.run.key = <same raw run key>              │
└────────────────────────────────┬──────────────────────────────────────┘
                                 │ OTLP/HTTP
                                 ▼
┌────────────────────── Authenticated Buildkite receiver ───────────────┐
│  Authenticate the suite                                               │
│  Derive a canonical, suite-scoped run UUID                            │
│  Publish Buildkite-Test-Run-ID with the OTLP payload                  │
└────────────────────────────────┬──────────────────────────────────────┘
                                 ▼
┌──────────────────────────── ta-ingestion ─────────────────────────────┐
│  Verify the resource run key derives to the canonical Kafka run UUID │
│  Write the canonical run_id onto every stored span                    │
└───────────────────────────────────────────────────────────────────────┘
```

The run key is untrusted correlation metadata, not authorization. The collector
validates the receiver's wire contract—1–255 printable, non-whitespace ASCII
characters—but never derives the canonical run UUID. Trusted organization and
suite identity come from receiver authentication.

## Execution lifecycle and correlation

Each instrumented example starts one parentless `test.execution` span with
`SpanKind::INTERNAL`. Synchronous instrumented work runs with that span active,
so standard trace and parent IDs establish the relationship to child spans.

The collector generates a candidate UUIDv7 before starting the span. When the
execution span is sampled, it uses that value for both:

```text
execution.external_id == test.execution.attributes["execution.externalId"]
```

`execution.externalId` and execution tags appear only on `test.execution`; they
are not copied to descendants. The span finishes after RSpec reports the final
result, including failures raised by outer hooks. The UUID format is an
implementation detail and consumers should treat the value as opaque.

## Ownership boundaries

The tested application is the service; the collector is instrumentation.

- If an SDK tracer provider already exists, the collector adds only its own span
  processor and preserves the provider's resource and `service.name`.
- If the default proxy provider is still active, the collector initializes the
  SDK provider without adding Buildkite metadata to its global resource.
- Buildkite resource attributes are merged into duplicated span data only in the
  Buildkite exporter. Customer exporters retain their original resources.
- Flush and shutdown affect only the Buildkite processor, never the provider or
  customer processors.
- Unsupported providers disable Buildkite span export without modifying them.

Because the provider is shared, customer exporters may observe collector-created
execution spans and spans from newly installed instrumentation. The isolation
contract applies to provider ownership, resources, processors, and lifecycle—not
to exclusive visibility of spans.

The OpenTelemetry SDK owns context propagation, batching, serialization, retry,
and OTLP transport. The collector does not implement a custom wire format or
delivery queue.

## Metadata contract

The collector adds these resource attributes when available:

| Attribute | Value |
| --- | --- |
| `buildkite.test.run.key` | Raw collector run key, also sent as `Buildkite-Test-Run-Key`. |
| `cicd.pipeline.run.id` | CI provider's run or workflow ID. |
| `cicd.pipeline.run.url.full` | Valid HTTP(S) run URL without credentials. |
| `cicd.pipeline.name` | Buildkite pipeline slug or GitHub workflow name. |
| `vcs.ref.head.revision` | Commit SHA or revision. |
| `vcs.ref.head.name` | Branch or tag name. |
| `vcs.ref.type` | `branch` or `tag` when known. |

The `test.execution` root carries:

| Attribute | Value |
| --- | --- |
| `execution.externalId` | Opaque ID shared with the execution upload. |
| `test.case.name` | Fully qualified RSpec example description. |
| `test.suite.name` | Full RSpec example-group description. |
| `test.case.result.status` | `pass` or `fail`. |
| `buildkite.test.case.result.status` | `skipped` when no standard value exists. |
| `code.file.path` / `code.line.number` | Canonical execution source location. |
| `buildkite.test.case.id` | RSpec example ID. |
| `buildkite.test.runner.name` / `.version` | RSpec identity. |
| `buildkite.test.execution.tag.<name>` | Existing execution tags. |

Source paths reuse the execution upload's normalization, including
`location_prefix` and shared-example call sites. Failure messages and stack
traces remain on the execution record rather than being copied into attributes.

## Instrumentation and data handling

For dogfooding, the collector installs all available Ruby OpenTelemetry
instrumentations and preserves the semantic attributes they emit. This gives us
evidence for a future allowlist without inventing a Buildkite-specific schema.
Database statement and command handling remains the responsibility of each
instrumentation, including its default sanitization.

The sole collector-owned transformation is reducing `process.command` to its
basename in the Buildkite export copy. The collector does not add arbitrary
environment variables, API tokens, HTTP headers or bodies, failure text,
usernames, host identifiers, or copies of execution metadata on child spans.
Source paths follow the existing execution-upload normalization and any configured
`location_prefix`.

## Deliberate dogfooding constraints

- RSpec is the only supported test framework for execution spans.
- Instrumentation is broad (`use_all` / `install_all`) rather than curated.
- SDK batch settings and best-effort in-memory delivery are unchanged.
- Normal suite shutdown flushes buffered spans; crashes and hard exits may lose
  telemetry.
- Sampling, payload limits, storage cost, framework expansion, and a production
  instrumentation allowlist will be decided from dogfooding evidence.

These constraints are experiment boundaries, not production guarantees.
