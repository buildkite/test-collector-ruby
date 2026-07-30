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
process.pid
process.command
process.runtime.name
process.runtime.version
process.runtime.description
telemetry.sdk.name
telemetry.sdk.language
telemetry.sdk.version
```

The Buildkite export copy normalizes `process.command` to its executable basename
(for example, `/opt/ruby/bin/rspec` becomes `rspec`). The collector does not
derive command arguments from this value, and the default production allowlist
should exclude `process.command_args`. This preserves the useful process identity
without exposing usernames, installation directories, or workspace paths. A
customer's other exporters continue to receive their original resource.

`service.name` identifies the customer application or component under test, not
the test runner, Test Engine suite, CI pipeline, or Buildkite collector. The
collector cannot reliably infer that identity from a repository, working
directory, or pipeline because each may contain or test multiple services. When
desired, customers should set the standard `OTEL_SERVICE_NAME` environment
variable (for example, `OTEL_SERVICE_NAME=checkout-service`). The collector
preserves a service name configured on an existing tracer provider. Without
either source, the Ruby SDK's `unknown_service` default is expected and Test
Engine should treat it as an unspecified service.

The collector adds the following when available:

| Attribute | Value |
| --- | --- |
| `buildkite.test.run.key` | The raw collector run key from `run_env["key"]`, also sent in the `Buildkite-Test-Run-Key` OTLP request header. |
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

`buildkite.test.run.key` is raw correlation metadata, not authorization. The
authenticated Buildkite receiver combines it with the trusted suite identity to
derive the canonical Test Engine run UUID. The collector does not derive or emit
that UUID. `cicd.pipeline.run.id` is also separate: it identifies the CI
provider's pipeline run and can differ for retries, local runs, and some CI
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

## Initial child span attribute policy

For the first release, preserve the semantic attributes emitted by the installed
Ruby OpenTelemetry instrumentations. Starting broad lets Test Engine evaluate
which attributes produce useful test intelligence before permanently discarding
them. It also avoids a Buildkite-specific schema that prematurely diverges from
the Ruby OTel ecosystem.

Rely on each Ruby OTel instrumentation's default sensitive-data handling instead
of reimplementing its statement or command parser in the collector. The bundled
PG, MySQL, Redis, and MongoDB instrumentations default to obfuscating their query
or command attributes. If a customer explicitly configures an instrumentation to
include raw values, preserve that upstream choice rather than silently applying a
second Buildkite-specific interpretation.

The one collector-owned exception is `process.command`: the Ruby SDK supplies an
absolute executable path, so the Buildkite export copy reduces it to a basename.
A customer's other exporters continue to receive their original resource.

The initial behavior is:

| Instrumentation data | Initial policy |
| --- | --- |
| HTTP and network semantic attributes | Preserve the attributes emitted by Ruby OTel, including method, status, destination, URL components, and connection details. |
| Database identity and operation attributes | Preserve attributes such as `db.system`, `db.operation`, database identity, and connection details. |
| Database query or command text | Preserve the value emitted by the instrumentation, including its default system-specific obfuscation. |
| `db.query.summary` | Preserve when supplied; it is a useful lower-cardinality grouping key. |
| `error.type` and protocol/database status attributes | Preserve for failure classification and test diagnosis. |
| Attributes from other installed instrumentations | Preserve initially, then review using observed sensitivity, utility, cardinality, and storage cost. |

### Database query handling

The installed Ruby instrumentation currently emits the experimental database
names `db.system`, `db.operation`, and `db.statement`. Keep those names rather
than rewriting customer telemetry. Newer instrumentation may instead emit stable
names such as `db.system.name`, `db.operation.name`, and `db.query.text`; preserve
those as emitted as well.

With its default obfuscation, SQL instrumentation replaces literal values with
placeholders while retaining query shape. For example:

```text
SELECT * FROM users WHERE email = 'person@example.com' AND id = 42
SELECT * FROM users WHERE email = ? AND id = ?
```

Redis, MongoDB, and other systems use their own serializers and obfuscators. Do
not run their output through a generic SQL parser. Keeping sanitization in the
instrumentation preserves its database-specific behavior and keeps the collector
compatible as Ruby OTel conventions evolve.

### Suggested evolution after the initial release

Do not drop attributes solely because two fields appear similar in one sample.
Measure representative suites and actual product queries first. Then evolve the
policy in reviewable stages:

| Level | Intended use | Attribute policy |
| --- | --- | --- |
| **Initial: broad with OTel defaults** | Maximize learning and test intelligence in the first release. | Preserve upstream Ruby OTel semantic attributes and their instrumentation-specific default sanitization. Normalize only the collector-owned `process.command` path. |
| **Curated** | Future storage-efficient default based on evidence. | Keep attributes used by Test Engine features and investigations; canonicalize or remove fields proven redundant, low-value, or disproportionately high-cardinality. |
| **Extended/debug** | Explicit troubleshooting when normal instrumentation omits needed detail. | Use the upstream instrumentation's per-integration options and clearly warn when a customer elects to include raw or sensitive values. |

Likely candidates for later redundancy review include legacy/stable semantic
convention duplicates, default ports, overlapping `server.*` and `net.peer.*`
fields, URL components duplicated by a safely normalized URL, and repeated
process identity. Keep trace identifiers and resource data out of metric
dimensions even when they remain useful on individual spans.

OTLP groups resources efficiently on the wire, while the ingestion schema may
repeat resource attributes on stored span rows. Treat wire size, stored bytes,
query performance, and attribute utility as separate measurements before deciding
what to remove or materialize.

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

The current PoC deliberately uses `use_all` to maximize instrumentation coverage
and preserves the emitted semantic attributes and upstream sanitization choices.
The only collector-owned attribute transformation is basename-only
`process.command` on the Buildkite export copy.

Broad attributes do not require broad trace ownership. Before enabling collection
by default, export only `test.execution` spans and their descendants. Unrelated
global application spans are outside the collector's ownership boundary even if
their individual attributes would be acceptable.

The following list applies to new metadata added by the Buildkite collector; it
does not rename standard attributes emitted by upstream instrumentation. Do not
automatically add:

- arbitrary process environment variables or collector `env` entries;
- commit messages, failure text, request/response bodies, or HTTP headers;
- API tokens or exporter authorization;
- process working directory, absolute command paths, usernames, host names,
  worker IPs, or stable host IDs;
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
- implementing curated and extended attribute level controls;
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
