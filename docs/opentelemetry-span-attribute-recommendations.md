# OpenTelemetry Span Attribute Recommendations

## Purpose

This document recommends which contextual information the Ruby test collector
should include in OpenTelemetry traces sent to Test Engine. It considers the
collector, Test Engine application, `ta-ingestion`, ClickHouse storage, current
OpenTelemetry semantic conventions, and the existing execution tag and
`run_env` contracts.

The goals are to:

- make traces useful for customer debugging;
- give Buildkite reliable intelligence about collector, runtime, test runner,
  and instrumentation versions in use;
- preserve enough context for future product capabilities;
- avoid copying data already available through execution/run correlation;
- control privacy, cardinality, payload size, and storage cost; and
- keep the emitted telemetry aligned with OpenTelemetry conventions.

## Executive recommendation

Use three metadata layers with distinct responsibilities:

```text
┌──────────────────────────────────────────────────────────────┐
│ Resource: facts about the tested process and CI run          │
│ Ruby runtime, OTel SDK, OS/architecture, customer service    │
├──────────────────────────────────────────────────────────────┤
│ Instrumentation scope: facts about who created each span     │
│ Buildkite collector version, OTel integration versions       │
├──────────────────────────────────────────────────────────────┤
│ test.execution root: facts about this specific test          │
│ Name, result, source location, runner, external ID            │
└──────────────────────────────────────────────────────────────┘
```

Do not copy root span attributes onto child spans. Resource attributes and
instrumentation scope already accompany every span, while trace and parent span
IDs associate children with `test.execution`.

Emit selected, structured run and VCS context as resource attributes so traces
are useful independently and all test roots can be grouped by run. Project
execution tags onto the root span only, under a Buildkite namespace and with the
same limits as the execution upload. Do not dump arbitrary `run_env` or process
environment variables into OTLP.

## Current state

### Execution upload

The JSON execution upload includes:

- `run_env`;
- run-level tags;
- execution identity and result fields;
- execution-level tags;
- the collector's existing trace history; and
- `external_id` when OTel export is enabled.

The Ruby collector's `run_env` currently includes, where available:

```text
CI
key
url
branch
commit_sha
number
job_id
message
execution_name_prefix
execution_name_suffix
language_version
version
collector
location_prefix
test_runner
trace_min_duration
```

The important version and identity values are:

```text
language_version = RUBY_VERSION
version          = Buildkite::TestCollector::VERSION
collector        = ruby-buildkite-test_collector
test_runner      = rspec, minitest, or cucumber
```

This means Test Engine already knows the Ruby version, collector version, test
runner, CI provider, run identity, branch, commit, and job information through
the run model. Those values do not need to be duplicated onto each span merely
for product intelligence.

### Current execution span

The collector creates one `test.execution` span around each RSpec example with:

```text
execution.externalId
test.name
test.id
test.file
```

Only the execution span receives `execution.externalId`. Child HTTP, SQL, Redis,
and other auto-instrumented spans inherit trace context, not parent attributes.

### Metadata already supplied by OpenTelemetry

The Ruby OpenTelemetry SDK automatically adds useful resource metadata. With
Ruby 3.3 and `opentelemetry-sdk` 1.13, the observed default resource includes:

```text
service.name
process.pid
process.command
process.runtime.name
process.runtime.version
process.runtime.description
telemetry.sdk.name
telemetry.sdk.language
telemetry.sdk.version
```

For example:

```ruby
{
  "service.name" => "unknown_service",
  "process.pid" => 1,
  "process.command" => "-e",
  "process.runtime.name" => "ruby",
  "process.runtime.version" => "3.3.12",
  "process.runtime.description" =>
    "ruby 3.3.12 (...) [aarch64-linux]",
  "telemetry.sdk.name" => "opentelemetry",
  "telemetry.sdk.language" => "ruby",
  "telemetry.sdk.version" => "1.13.0",
}
```

The collector also acquires its tracer with:

```ruby
OpenTelemetry.tracer_provider.tracer(
  "buildkite-test-collector",
  Buildkite::TestCollector::VERSION,
)
```

This produces the OTLP-native collector identity:

```text
scope_name    = buildkite-test-collector
scope_version = <collector version>
```

Child spans created by an OTel integration similarly carry that integration's
scope name and version. This makes it possible to identify versions of
instrumentations such as `opentelemetry-instrumentation-net_http`,
`opentelemetry-instrumentation-active_record`, and
`opentelemetry-instrumentation-redis` without adding custom attributes.

### Ingestion and storage

`ta-ingestion` stores one ClickHouse row per span. Each row contains:

```text
service_name
resource_attributes
scope_name
scope_version
span_attributes
execution_external_id
```

Resource and scope information from the OTLP request is therefore already
available for analysis. Attribute values are converted to strings in the
current query-oriented ClickHouse projection.

The projection repeats resource information for every span row. That makes
resource metadata useful but also means the resource set should remain small
and intentional.

The Test Engine trace reader does not yet expose every stored resource and scope
field. This does not affect the collector contract. The collector should emit
sensible defaults now so the data is retained; product queries and presentation
can use it later without requiring another collector rollout.

## Recommended contract

### Resource attributes

Resource attributes should describe the process producing telemetry. They
naturally apply to the execution span and every descendant.

| Attribute | Source | Recommendation |
| --- | --- | --- |
| `telemetry.sdk.name` | OTel SDK | Keep the automatic value. |
| `telemetry.sdk.language` | OTel SDK | Keep the automatic `ruby` value. |
| `telemetry.sdk.version` | OTel SDK | Keep the automatic value. This is not the collector version. |
| `process.runtime.name` | OTel SDK | Keep the automatic `RUBY_ENGINE` value. |
| `process.runtime.version` | OTel SDK | Keep the automatic `RUBY_VERSION` value. |
| `process.runtime.description` | OTel SDK | Keep it. It provides engine, patchlevel, platform, and architecture context useful for support. |
| `host.arch` | Collector or detector | Consider adding as a structured, low-cardinality value. |
| `os.type` | Collector or detector | Consider adding as a structured, low-cardinality value. |
| `service.name` | Customer/SDK | Preserve customer configuration; do not identify the collector as the service. |
| `service.version` | Customer | Preserve if explicitly supplied. Do not use it for collector version. |
| `deployment.environment.name` | Customer | Preserve only when explicitly configured; do not infer it from Rails or CI variables. |
| `cicd.pipeline.run.id` | Collector | Emit by default when a provider-native run ID is available. This is the primary grouping key for all test roots in a run. |
| `cicd.pipeline.run.url.full` | Collector | Emit by default when a valid HTTP(S) run URL is available. |
| `cicd.pipeline.name` | Collector | Emit when the provider supplies a real workflow or pipeline name. |
| `buildkite.test.run.id` | Collector | Emit the same external run key used in `run_env["key"]` when Test Engine run identity does not map exactly to a CI pipeline run. |
| `vcs.ref.head.revision` | Collector | Emit the commit/revision when available. |
| `vcs.ref.head.name` | Collector | Emit the branch or tag name when available. |
| `vcs.ref.type` | Collector | Emit only when branch versus tag is reliably known. |

The collector currently configures:

```ruby
c.service_name = "buildkite-test-collector-ruby"
```

This identifies the collector as the service for all HTTP, SQL, Redis, and other
spans emitted by the tested process. Semantically, the tested application is the
service and the collector is instrumentation. Collector identity is already
represented by `scope_name` and `scope_version`.

The forced service name should therefore be removed or revisited. A customer's
`OTEL_SERVICE_NAME` should be preserved when present; otherwise the SDK default
is acceptable because trusted organization and suite identity come from the
authenticated ingestion boundary.

### Root `test.execution` attributes

OpenTelemetry now defines development-stage test attributes. The collector
should adopt those names rather than expanding its current custom `test.*`
vocabulary. "Converge" here means replacing provisional Buildkite names with
the corresponding OpenTelemetry names. Because this project is greenfield, the
standard names should be used now instead of maintaining both indefinitely.

| Attribute | Type | Value |
| --- | --- | --- |
| `execution.externalId` | string | Existing opaque correlation ID; parentless execution root only. |
| `test.case.name` | string | Fully qualified human-readable example name. |
| `test.suite.name` | string | RSpec example-group description when meaningful. |
| `test.case.result.status` | string | `pass`, `fail`, or a documented custom `skipped` value. |
| `code.file.path` | string | Normalized repository-relative source path. |
| `code.line.number` | integer | Source line when reliably available. |
| `buildkite.test.case.id` | string | RSpec example ID; there is no standard test case ID attribute. |
| `buildkite.test.runner.name` | string | `rspec`. |
| `buildkite.test.runner.version` | string | RSpec version. |

The current attributes should be migrated as follows:

```text
test.name  → test.case.name
test.file  → code.file.path
test.id    → buildkite.test.case.id
```

If deployed consumers already depend on the current names, dual-write for one
release and have readers coalesce old and new names. If the OTLP contract is
still pre-GA, migrate atomically now.

The upstream test conventions remain development-stage. The collector should
document the semantic convention version it adopts and avoid adding further
unnamespaced keys under `test.*`.

### Span status and result

The root span should be updated after the example finishes:

| Test outcome | `test.case.result.status` | OTel span status |
| --- | --- | --- |
| Passed | `pass` | `UNSET` |
| Failed | `fail` | `ERROR` |
| Skipped/pending | `skipped` | `UNSET` |
| Wrapper or hook exception before a reliable result | omitted | `ERROR` |

The current OTel wrapper passes attributes before `example.run` and discards the
span yielded by `in_span`. It must expose that span, or accept an end-of-test
callback, to set final result and status.

Failure reason, expanded failure output, and stack traces should not be copied
into span attributes. They already exist on the execution and can contain large
or sensitive customer data.

### Instrumentation scope

Collector identity should remain in the standard scope fields:

```text
scope_name    = buildkite-test-collector
scope_version = Buildkite::TestCollector::VERSION
```

Do not duplicate collector version as:

```text
service.version
telemetry.sdk.version
buildkite.collector.version
```

The first identifies the customer service, the second identifies the OTel SDK,
and the third would duplicate an existing OTLP field.

Scope metadata on child spans also provides an inventory of the OTel
instrumentations and versions actively producing telemetry. This is more
reliable than inspecting the customer's loaded gem list.

## Execution tags

### Project execution tags onto the root span

Execution tags are already persisted with the execution and exposed in the Test
Engine UI. The external ID provides a deterministic join from the execution
span to that authoritative record. However, including the same tag snapshot on
the root makes the trace independently queryable and allows root spans to be
grouped and filtered without first joining to executions.

The intended lookup is:

```text
child span
  → trace_id
  → test.execution root
  → execution.externalId
  → execution
  → execution.tags and run.env
```

Emit each tag as a root-only attribute under a Buildkite namespace:

```text
execution tag: component=checkout
span attribute: buildkite.test.execution.tag.component=checkout
```

The collector should apply tags after the example finishes because
`tag_execution` can be called during execution. Both the JSON execution and root
span must use the same in-memory tag snapshot. Reserved root attributes must win
over customer tag names.

Execution tag limits currently cover tag count and key/value byte sizes. The
OTLP projection should reuse those same limits instead of creating a separate,
unbounded tag contract. Tags must remain root-only; copying them to every child
would multiply storage without improving trace relationships.

Customers should be able to disable tag projection or redact selected keys when
their tags contain sensitive values. The execution remains the authoritative
record if the OTLP path drops or redacts a tag.

## Environment metadata

"Environment" must have a precise definition. The collector should not
automatically emit:

- all process environment variables;
- arbitrary `Buildkite::TestCollector.env` entries;
- `RAILS_ENV`;
- `RACK_ENV`;
- `APP_ENV`; or
- values guessed from `CI=true`.

Arbitrary environment variables can contain credentials. Rails test processes
will overwhelmingly report `test`, which provides little differentiation.
Collector `env` is untyped and can override built-in run fields.

Support the standard resource attribute only when explicitly configured:

```text
deployment.environment.name
```

Customers can provide it through normal OTel configuration such as
`OTEL_RESOURCE_ATTRIBUTES`. The collector should not infer a value.

## CI/CD and VCS context

OpenTelemetry's CI/CD resource conventions include:

```text
cicd.pipeline.name
cicd.pipeline.run.id
cicd.pipeline.run.url.full
cicd.worker.id
cicd.worker.name
vcs.ref.head.revision
vcs.ref.head.name
vcs.ref.type
```

These attributes should be part of the default trace contract. In particular,
`cicd.pipeline.run.id` allows Test Engine to select all `test.execution` roots
from one run without joining through the execution table. It also allows traces
to remain understandable if they are exported, replayed, or queried separately
from execution records.

There are two related identities that should not be conflated:

- `cicd.pipeline.run.id` is the provider-native CI pipeline/workflow run, such
  as a Buildkite build ID or GitHub Actions run ID; and
- `buildkite.test.run.id` is the Test Engine collector run key, matching the
  value sent as `run_env["key"]` on the JSON path.

They may have the same value for Buildkite, but they need not be identical for
every provider, local execution, retry, or future upload model. Emit both when
both concepts are known. Grouping must also be scoped by the authenticated suite
because neither customer-provided identity is globally unique.

A run ID is high-cardinality because it is normally unique per run, but that is
expected for traces: trace IDs, span IDs, execution IDs, and run IDs are all
identity fields. High cardinality is most dangerous when attached to metrics,
where it creates a new time series for every value. The OTel CI/CD resource
convention specifically warns that pipeline-run resources on metrics must be
opt-in. For this trace-only pipeline, cardinality is a query and index design
consideration, not a reason to omit the identity.

The current ClickHouse projection repeats resource maps on every span row, so a
run ID and URL have a measurable byte cost. That cost is bounded and justified
by the grouping capability. Avoid treating run ID as `LowCardinality(String)`
or building an unscoped global aggregation around it; query it within trusted
organization, suite, and time boundaries.

When run grouping becomes a product query, promote the selected resource value
to a dedicated `String` column such as `cicd_pipeline_run_id` during ingestion
and add an equality-oriented skipping index or projection based on measured
queries. Do not rely indefinitely on scanning the generic resource map, and do
not use ClickHouse `LowCardinality(String)` for a mostly unique run ID. Retain
the raw resource attribute as the interoperable OTLP contract.

When adding CI/VCS resources:

- derive them from typed provider-specific variables rather than the merged
  and customer-overridable `CI.env` hash;
- use provider-native run IDs;
- do not fabricate pipeline identity for generic CI;
- validate URLs as bounded HTTP(S) URLs without embedded credentials;
- set `vcs.ref.type` only when branch versus tag is reliably known; and
- measure repeated resource bytes per span before rollout.

Examples of provider-specific run identity include:

- Buildkite: `BUILDKITE_BUILD_ID`;
- GitHub Actions: `GITHUB_RUN_ID`, not a synthesized action/number key;
- CircleCI: `CIRCLE_WORKFLOW_ID`; and
- Codeship: `CI_BUILD_ID`, while noting that `CI_PULL_REQUEST` is not a run URL.

CI job IDs should not be modeled as pipeline-run resource identity. A future
pipeline task span is the more appropriate place for job/task metadata.

## Data that should not be collected automatically

Do not automatically add:

- arbitrary process environment variables;
- arbitrary execution or run tags;
- commit messages;
- failure text or expanded failures as attributes;
- full command-line arguments;
- process working directory;
- usernames;
- host names or stable host IDs;
- CI worker IDs or IP addresses;
- repository URLs unless required by a concrete product feature;
- request or response bodies;
- HTTP headers;
- API tokens or exporter authorization;
- every loaded gem and version; or
- copies of execution metadata on child spans.

A complete gem inventory may expose private gem names, is potentially large,
and creates uncontrolled cardinality. Add individual support-critical versions
instead. RSpec version is the highest-value first addition. Rails or database
adapter versions should be added only after a concrete support or product need
is established.

## PoC instrumentation breadth

The current PoC calls:

```ruby
c.use_all
```

This deliberately maximizes coverage during the PoC. It can enable integrations
that capture:

- full URLs and query strings;
- SQL statements;
- Redis keys;
- messaging destinations; and
- third-party instrumentation attributes.

`use_all` is not a blocker for choosing or emitting sensible default resource
and root-span attributes in this experiment. Before a production commitment,
revisit whether to retain it, provide instrumentation controls, or establish
sanitization defaults. A production ingestion boundary should also consider
limits for:

- attribute count;
- key bytes;
- value bytes;
- total attribute bytes per span;
- event and link attribute sizes; and
- known sensitive keys.

Customer-authored resource attributes must never be trusted for organization or
suite identity. Trusted tenancy must continue to come from authenticated
ingestion metadata.

## Correlation correctness prerequisite

`ta-ingestion` promotes `execution.externalId` only when it appears exactly once
as a valid string on a parentless span.

The current `in_span` call inherits any ambient OTel context. If a customer's
test process already has an active span, `test.execution` becomes a child and
its external ID is not promoted, silently breaking correlation.

Enforce root creation by temporarily making an empty context current while
calling `in_span`:

```ruby
OpenTelemetry::Context.with_current(OpenTelemetry::Context.empty) do
  @tracer.in_span(name, attributes: span_attributes, kind: :internal) do |span|
    yield span
  end
end
```

`in_span` makes the new execution span active inside its block, so HTTP, SQL,
Redis, and other auto-instrumented work still becomes its child. When the block
finishes, `with_current` restores the caller's prior context. This guarantees
that `test.execution.parent_span_id` is empty without losing child propagation.

Add a contract test that activates an unrelated ambient span before
`in_test_span` and verifies that:

- `test.execution` has no parent;
- the auto-instrumented operation is a child of `test.execution`;
- both spans share a trace ID; and
- `execution.externalId` is present only on `test.execution`.

If job or ambient trace context later needs to remain visible, capture it before
clearing the context and add it as a span link rather than making it the parent.

## Product intelligence opportunities

Existing OTLP fields can answer useful adoption and support questions without
new collector attributes:

| Question | Source |
| --- | --- |
| Which collector versions are active? | Root `scope_name` and `scope_version` |
| Which Ruby versions are active? | `process.runtime.version` |
| Which Ruby engines are active? | `process.runtime.name` |
| Which architectures/platforms are involved? | `process.runtime.description`, later `host.arch` and `os.type` |
| Which OTel SDK versions are active? | `telemetry.sdk.version` |
| Which instrumentations generate child spans? | Child `scope_name` |
| Which instrumentation versions are active? | Child `scope_version` |
| Which test runner is used? | Existing run `test_runner` |
| Which runner version is used? | Proposed `buildkite.test.runner.version` |
| Which test roots belong to one run? | `cicd.pipeline.run.id` |
| Which roots correspond to one Test Engine collector run? | `buildkite.test.run.id` |
| Which branches or revisions exhibit a behavior? | `vcs.ref.head.name` and `vcs.ref.head.revision` |

For frequently queried dimensions, materialize selected fields rather than
scanning attribute maps repeatedly:

```text
collector_scope_version
runtime_name
runtime_version
otel_sdk_version
test_runner_name
test_runner_version
os_type
host_arch
```

Do not create global indexes for branch, commit SHA, run URL, test case ID, or
arbitrary attribute keys. High-cardinality queries should remain scoped by
trusted organization, suite, and time boundaries.

Use of customer telemetry for aggregate product intelligence should have an
explicit privacy and access policy. Resource/span attributes are customer data,
even when their names follow standard conventions.

## Rollout plan

### Phase 0: correlation correctness

1. Guarantee that `test.execution` is parentless.
2. Add an ambient-context regression test.
3. Add cross-repository fixture tests proving root-only external ID promotion,
   child relationships, resource/scope storage, and execution correlation.
4. Remove or revisit the forced collector `service.name`.

Provider coexistence, `use_all`, sanitization, and tighter per-attribute limits
remain production follow-ups rather than blockers for this PoC's attribute
defaults.

### Phase 1: high-value test context

1. Emit `cicd.pipeline.run.id` and available pipeline run URL by default.
2. Emit `buildkite.test.run.id` from the same run key used by the execution upload.
3. Emit available VCS revision and reference context.
4. Adopt `test.case.name` and `test.suite.name`.
5. Add `test.case.result.status` after execution.
6. Set OTel span status from the final result.
7. Adopt `code.file.path` and `code.line.number`.
8. Add Buildkite-namespaced test case ID and runner name/version.
9. Project bounded execution tags onto the root span.
10. Replace the existing `test.name`, `test.id`, and `test.file` names.

### Phase 2: use existing product intelligence

1. Query existing runtime, OTel SDK, collector scope, and child instrumentation
   versions.
2. Expose selected resource and scope fields through the trace reader where
   useful to customers.
3. Materialize frequently queried low-cardinality dimensions.
4. Measure attribute presence, distinct values, payload size, and bytes per
   span without adding customer identifiers to global operational metrics.

### Phase 3: structured environment context and refinement

1. Add `host.arch` and `os.type` if structured platform analysis is useful.
2. Add pipeline name where provider-specific mappings are reliable.
3. Add customer controls for sensitive resource attributes and tag projection.
4. Refine ClickHouse materialized fields and indexes from observed query shapes.

## Recommended initial additions

The first collector additions should be limited to:

```text
test.case.name
test.suite.name
test.case.result.status
code.file.path
code.line.number
buildkite.test.case.id
buildkite.test.runner.name
buildkite.test.runner.version
cicd.pipeline.run.id
cicd.pipeline.run.url.full
buildkite.test.run.id
vcs.ref.head.revision
vcs.ref.head.name
buildkite.test.execution.tag.<tag-key>
```

Ruby, OTel SDK, collector, and instrumentation versions are already available
through resource and instrumentation scope metadata. Execution tags remain
authoritative on the execution record but are also projected onto the root for
standalone trace filtering. Sensitive projections should be configurable rather
than making the default trace contract sparse.

## Source references

### Ruby collector

- `lib/buildkite/test_collector/otel.rb`: provider, exporter, resource service
  name, tracer scope, and root span attributes.
- `lib/buildkite/test_collector/ci.rb`: run environment and CI provider mapping.
- `lib/buildkite/test_collector/library_hooks/rspec.rb`: execution lifecycle,
  external ID generation, and test attributes.
- `lib/buildkite/test_collector/trace.rb`: execution serialization and tags.
- `spec/test_collector/rspec_plugin/correlation_spec.rb`: root/child correlation
  and external-ID placement contract.
- `docs/opentelemetry-architecture-notes.md`: PoC architecture and decisions.

### Buildkite application

- `app/models/analytics/upload/http_request.rb`: execution upload boundary.
- `app/models/analytics/karafka/produce_upload.rb`: ingestion headers and tag
  limits.
- `app/consumers/analytics/run_consumer.rb`: `run_env` persistence.
- `app/models/analytics/execution.rb`: execution fields, tags, and external ID.
- `app/presenters/analytics/execution_presenter.rb`: execution metadata and span
  presentation.
- `db/test_engine_v2_clickhouse_structure.sql`: execution, tag, and span storage.

### ta-ingestion

- `src/main/java/com/buildkite/ta/model/OtlpTraceRecordDecoder.java`: OTLP
  decoding and request safety bounds.
- `src/main/java/com/buildkite/ta/model/OtlpTraceClickhouseMapper.java`: resource,
  scope, attribute, and external-ID projection.
- `src/main/java/com/buildkite/ta/model/ExecutionV2ClickhouseMapper.java`:
  execution fields, tags, and external-ID validation.
- `src/main/java/com/buildkite/ta/model/collector/TagLimits.java`: execution tag
  limits.
- `docs/otlp-ingestion-architecture.md`: OTLP ingestion and correlation design.

### OpenTelemetry

- Resource semantic conventions:
  <https://opentelemetry.io/docs/specs/semconv/resource/>
- Process and Ruby runtime conventions:
  <https://opentelemetry.io/docs/specs/semconv/resource/process/>
- CI/CD and VCS resource conventions:
  <https://opentelemetry.io/docs/specs/semconv/resource/cicd/>
- CI/CD span conventions:
  <https://opentelemetry.io/docs/specs/semconv/cicd/cicd-spans/>
- Test attribute registry:
  <https://opentelemetry.io/docs/specs/semconv/registry/attributes/test/>
