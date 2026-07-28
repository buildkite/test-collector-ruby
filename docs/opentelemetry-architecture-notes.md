# OpenTelemetry PoC Architecture and Decisions

## Purpose

This proof of concept tests whether the Ruby test collector can represent an
RSpec execution as an OpenTelemetry trace while preserving the existing Test
Engine execution upload.

It is intended to prove three things:

1. one test execution can be represented by a `test.execution` span;
2. operations observed by standard OTel instrumentation can become descendants
   of that span; and
3. the trace and the separately uploaded execution can be joined reliably.

This document covers decisions made in this repository. The OTLP receiver,
ingestion pipeline, storage, and UI are outside its scope.

## Architecture being tested

```text
┌──────────────────────────────── RSpec process ───────────────────────────────┐
│                                                                              │
│  RSpec around(:each)                                                         │
│    │                                                                         │
│    ├── generate one external ID                                              │
│    │                                                                         │
│    ├── start `test.execution`                                                │
│    │     ├── execution.externalId = external ID                              │
│    │     └── run example with the span active                                │
│    │           └── HTTP, SQL, Redis, ... auto-instrumented child spans       │
│    │                                                                         │
│    └── create execution result                                               │
│          └── external_id = the same external ID                              │
│                                                                              │
│  Existing uploader ────────────────────────────▶ Test Engine upload endpoint │
│  OTel BatchSpanProcessor ──▶ OTLP exporter ───▶ configured OTLP endpoint     │
│                                                                              │
│  RSpec after(:suite) ──▶ force flush ──▶ shut down tracer provider           │
└──────────────────────────────────────────────────────────────────────────────┘
```

The collector owns the RSpec lifecycle integration and correlation ID. The OTel
SDK owns context propagation, span batching, protobuf serialization, and
OTLP/HTTP transport. The two delivery paths remain independent.

## Correlation contract

When OTel export is enabled, the RSpec hook generates one ID with
`Buildkite::TestCollector::UUID.v7` and passes that same value to both outputs:

```text
execution.external_id == test.execution.attributes["execution.externalId"]
```

Only `test.execution` carries `execution.externalId`. Child spans are associated
with it through standard `trace_id` and `parent_span_id` relationships. The
collector does not add tenant metadata or ingestion identifiers to spans.

The generated value is currently a UUIDv7, providing time ordering and storage
locality for persisted execution IDs. Its UUID version is not part of the
contract; consumers should treat the external ID as opaque.

## Architectural decisions we expect to keep

These choices express the intended architecture rather than PoC convenience.

### Generate the correlation ID once

The RSpec lifecycle is the one place that knows both the execution upload and
its OTel span. Generating the ID there and passing it to both paths prevents
independent ID generation from producing records that cannot be joined.

### Put the external ID on the execution span only

Copying the ID to every child would duplicate data and introduce a second
propagation mechanism. Standard trace relationships already connect child spans
to `test.execution`, so the Buildkite-specific correlation attribute belongs at
the execution boundary.

### Keep `external_id` as a first-class execution field

Correlation is part of the execution's identity, not user metadata. It is
therefore serialized as `external_id` in the execution upload instead of being
encoded as a user-visible tag.

### Use standard OpenTelemetry protocols and relationships

The collector delegates span context, parent-child relationships, batching,
protobuf encoding, and HTTP transport to OpenTelemetry. It does not introduce a
custom span processor, wire format, batching queue, or descendant propagation
mechanism.

This keeps the collector interoperable and limits the amount of telemetry
infrastructure it owns.

### Keep telemetry additive and non-fatal

OTel export is opt-in through `otlp_endpoint:` or
`BUILDKITE_ANALYTICS_OTLP_ENDPOINT`. Configuration failures warn and disable span
export rather than failing the customer's test suite. The existing execution
upload continues independently.

### Make OTel a hard dependency of the core collector

The collector directly depends on the OTel SDK, OTLP exporter, and instrumentation
gems so span export works without additional host application setup. Because
current OTel gems require Ruby 3.3 or newer, this change ships in v3 of the
collector and raises its minimum Ruby version to 3.3.

## PoC shortcuts, not product commitments

These choices make the experiment small and runnable. They need not survive a
production implementation.

| Shortcut | Why it is acceptable for the PoC | Why it should be revisited |
| --- | --- | --- |
| Configure the global tracer provider | It is the shortest path to a working exporter and active context. | It can interfere with a customer's existing provider, and shutdown can affect telemetry the collector does not own. |
| Call `use_all` | It quickly demonstrates HTTP, SQL, Redis, and other child spans. | It monkeypatches broadly, can duplicate customer instrumentation, and installs more integrations than the collector needs. |
| Use the SDK's default batch processor settings | It avoids inventing tuning before measuring representative suites. | A batch may exceed receiver limits, and queue size, timeout, retry, and compression behavior vary by SDK version. |
| Integrate only with RSpec | It proves the lifecycle and correlation model with one framework. | Minitest and Cucumber do not create execution spans or flush OTel batches. |
| Flush in `after(:suite)` | It sends the final partial batch after normal RSpec completion. | Crashes, hard exits, and some process lifecycles can still lose buffered spans. |

## Rejected or superseded approaches

### Build collector-specific transport or batching

Custom OTLP encoding, request grouping, or buffering would duplicate SDK
responsibilities and make the output less standard. The PoC intentionally uses
the SDK exporter and accepts its batching semantics.

### Make a Buildkite job span the execution span's parent

An execution should be independently traceable. If job trace context becomes
available, a span link is a better model for that relationship than making all
test executions descendants in one job trace. No job link is implemented in
this PoC.

## Decisions deferred until after the PoC

The experiment does not answer these production questions:

- **Existing OTel ownership:** how to detect and reuse a customer's provider
  without reconfiguring or shutting it down.
- **Instrumentation set:** which integrations should be enabled when the host
  does not already provide instrumentation.
- **Root isolation:** whether `test.execution` must explicitly ignore an active
  host span. The current `in_span` call can inherit ambient context.
- **Job relationship:** how job trace context is supplied and represented as an
  OTel span link.
- **Batch limits:** what queue and export sizes fit real test suites and receiver
  payload limits.
- **Delivery expectations:** acceptable loss, retry, duplicate, and shutdown
  behavior. The current in-memory batching is best effort, not durable storage.
- **Framework lifecycle:** how Minitest, Cucumber, parallel workers, and abnormal
  exits create and flush execution traces.
- **Version support:** which OTel and Ruby versions a supported integration will
  guarantee.

## PoC success criteria

The PoC is successful if it demonstrates that:

- an enabled RSpec example produces one `test.execution` span;
- synchronous auto-instrumented work is parented to that span;
- exactly one external ID is generated for the example;
- the same value appears in the execution upload and on `test.execution`;
- descendants do not require a copied Buildkite correlation attribute; and
- OTel failures do not prevent the existing execution result from being
  collected.

Success does not imply that packaging, provider coexistence, instrumentation
selection, batching limits, framework coverage, or delivery guarantees are
production-ready.
