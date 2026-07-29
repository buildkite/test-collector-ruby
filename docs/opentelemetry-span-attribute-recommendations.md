# OpenTelemetry Span Attribute Contract

## Purpose

This document defines the OpenTelemetry metadata emitted by the Ruby test
collector. The contract should make traces independently useful while
preserving correlation with Test Engine's JSON execution records.

## Metadata model

Use each OpenTelemetry layer for its intended purpose:

```text
┌─────────────────────────────────────────────────────────────┐
│ Resource: tested process and CI run                         │
│ Customer service, Ruby/OTel runtime, run and VCS identity   │
├─────────────────────────────────────────────────────────────┤
│ Instrumentation scope: producer of each span                │
│ Collector or OTel instrumentation name and version          │
├─────────────────────────────────────────────────────────────┤
│ test.execution root: this specific test execution           │
│ Correlation, name, result, source, runner, execution tags    │
└─────────────────────────────────────────────────────────────┘
```

Root attributes are not copied to child spans. Trace and parent span IDs provide
that relationship. Resource attributes and instrumentation scope already
accompany every exported span.

## Required correlation and lifecycle behavior

Each instrumented RSpec example has one `test.execution` span with
`SpanKind::INTERNAL`.

The collector must guarantee that:

- `test.execution` is parentless, even when an unrelated customer span is active;
- auto-instrumented work during the example is its child;
- `execution.externalId` appears only on `test.execution`;
- the same UUIDv7 is sent as the JSON execution's `external_id`;
- the span is ended after RSpec reports its final result, including failures from
  outer hooks; and
- OTel failures never fail the test or prevent the JSON execution upload.

`ta-ingestion` promotes `execution.externalId` only from a parentless span, so
root creation is part of the correlation contract rather than a presentation
choice.

## Resource attributes

The Ruby SDK already supplies runtime and SDK context. Keep these automatic
values instead of duplicating them:

```text
service.name
process.runtime.name
process.runtime.version
process.runtime.description
telemetry.sdk.name
telemetry.sdk.language
telemetry.sdk.version
```

The collector adds the following when available:

| Attribute | Value |
| --- | --- |
| `buildkite.test.run.id` | The same collector run key sent as `run_env["key"]`. |
| `cicd.pipeline.run.id` | Provider-native run ID. |
| `cicd.pipeline.run.url.full` | Valid HTTP(S) run URL without credentials. |
| `cicd.pipeline.name` | Provider workflow or pipeline name. |
| `vcs.ref.head.revision` | Commit SHA or revision. |
| `vcs.ref.head.name` | Branch or tag name. |
| `vcs.ref.type` | `branch` or `tag` when reliably known. |

Provider-native run IDs are:

- Buildkite: `BUILDKITE_BUILD_ID`;
- GitHub Actions: `GITHUB_RUN_ID`;
- CircleCI: `CIRCLE_WORKFLOW_ID`; and
- Codeship: `CI_BUILD_ID`.

Do not label Codeship's `CI_PULL_REQUEST` as a run URL. For Buildkite tag builds,
use `BUILDKITE_TAG` as the VCS ref name.

`buildkite.test.run.id` and `cicd.pipeline.run.id` are deliberately separate.
The first identifies Test Engine's collector run; the second identifies the CI
provider's pipeline run. They can differ for retries, local runs, and some CI
providers.

Run IDs are naturally high-cardinality trace identity fields. This is acceptable
for traces; do not use them as metric dimensions. If run grouping becomes a hot
query, materialize it as a normal ClickHouse `String` rather than
`LowCardinality(String)` or repeatedly scanning the resource map.

## Root span attributes

| Attribute | Value |
| --- | --- |
| `execution.externalId` | Opaque UUIDv7 shared with the JSON execution. |
| `test.case.name` | Fully qualified RSpec example description. |
| `test.suite.name` | Full RSpec example-group description. |
| `test.case.result.status` | Standard `pass` or `fail`. |
| `buildkite.test.case.result.status` | `skipped` when no standard test-case value exists. |
| `code.file.path` | Canonical execution filename. |
| `code.line.number` | Corresponding source line. |
| `buildkite.test.case.id` | RSpec example ID. |
| `buildkite.test.runner.name` | `rspec`. |
| `buildkite.test.runner.version` | Loaded RSpec version. |

`code.file.path` must reuse the JSON execution's filename logic. This preserves
`location_prefix`, UTF-8 normalization, and shared-example call sites. Do not
introduce a second path-normalization implementation or expose unstable absolute
CI workspace paths.

### Result mapping

| RSpec result | Span attribute | OTel status |
| --- | --- | --- |
| Passed | `test.case.result.status=pass` | `UNSET` |
| Failed | `test.case.result.status=fail` | `ERROR` |
| Pending/skipped | `buildkite.test.case.result.status=skipped` | `UNSET` |

Failure messages, expanded failures, and stack traces remain on the execution
record. They can be large or sensitive and should not be copied into attributes.

## Execution tags

Project execution tags onto the root only:

```text
execution tag: component=checkout
span attribute: buildkite.test.execution.tag.component=checkout
```

Apply tags after the example because `tag_execution` can run inside the test.
The span and JSON execution must use the same in-memory tag snapshot. The JSON
execution remains authoritative.

Before production rollout, align OTLP tag count and byte limits with the
execution ingestion limits and add controls for redaction or disabling tag
projection.

## Provider and instrumentation ownership

The tested application is the service; the collector is instrumentation.
Therefore:

- preserve the customer's tracer provider, resource, and `service.name`;
- attach only a Buildkite-owned span processor when the provider supports it;
- merge Buildkite run resource attributes only into Buildkite's export copy;
- never leak Buildkite-only resource metadata to customer exporters;
- flush and shut down only the Buildkite processor; and
- leave an unsupported custom provider untouched and disable Buildkite export.

Collector identity is represented by standard instrumentation scope fields:

```text
scope_name    = buildkite-test-collector
scope_version = Buildkite::TestCollector::VERSION
```

Do not put the collector version in `service.version`, which belongs to the
customer service, or `telemetry.sdk.version`, which belongs to the OTel SDK.
Child instrumentation scope also gives Buildkite an inventory of active OTel
integrations and their versions.

## Collection boundaries

The PoC deliberately uses `use_all` to maximize instrumentation coverage. It may
capture URLs, SQL, Redis keys, messaging destinations, and third-party
attributes. This is accepted for the experiment but needs production controls.

Do not automatically add:

- arbitrary process environment variables or collector `env` entries;
- commit messages, failure text, request/response bodies, or HTTP headers;
- API tokens or exporter authorization;
- process working directory, usernames, host names, worker IPs, or stable host IDs;
- every loaded gem and version; or
- copies of execution metadata on child spans.

Customers may set standard values such as `deployment.environment.name` through
normal OTel configuration. The collector should not infer them from `RAILS_ENV`,
`RACK_ENV`, or `CI=true`.

Authenticated ingestion metadata remains the source of trusted organization and
suite identity. Customer-authored resource attributes must never be trusted for
tenancy.

## Deferred decisions

The following are intentionally outside the current PoC contract:

- sampling policy and behavior under `OTEL_TRACES_SAMPLER`;
- creating execution records for `xit` and metadata-skipped examples whose RSpec
  around hooks never run;
- replacing `use_all` with an instrumentation allowlist;
- customer controls for sensitive attributes and tag projection;
- structured `host.arch` and `os.type` attributes; and
- final ingestion limits for attributes, events, and links.

## Implementation references

Ruby collector:

- `lib/buildkite/test_collector/otel.rb`
- `lib/buildkite/test_collector/library_hooks/rspec.rb`
- `lib/buildkite/test_collector/rspec_plugin/reporter.rb`
- `lib/buildkite/test_collector/rspec_plugin/trace.rb`
- `spec/test_collector/rspec_plugin/correlation_spec.rb`

Related backend sources:

- `ta-ingestion/src/main/java/com/buildkite/ta/model/OtlpTraceRecordDecoder.java`
- `ta-ingestion/src/main/java/com/buildkite/ta/model/OtlpTraceClickhouseMapper.java`
- `ta-ingestion/src/main/java/com/buildkite/ta/model/ExecutionV2ClickhouseMapper.java`
- `buildkite/db/test_engine_v2_clickhouse_structure.sql`

OpenTelemetry conventions:

- <https://opentelemetry.io/docs/specs/semconv/resource/>
- <https://opentelemetry.io/docs/specs/semconv/resource/process/>
- <https://opentelemetry.io/docs/specs/semconv/resource/cicd/>
- <https://opentelemetry.io/docs/specs/semconv/registry/attributes/test/>
