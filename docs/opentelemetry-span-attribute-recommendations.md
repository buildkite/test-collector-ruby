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

## Initial child span attribute policy

For the first release, preserve the semantic attributes emitted by the installed
Ruby OpenTelemetry instrumentations. Starting broad lets Test Engine evaluate
which attributes produce useful test intelligence before permanently discarding
them. It also avoids a Buildkite-specific schema that prematurely diverges from
the Ruby OTel ecosystem.

This is not permission to export known-sensitive values unchanged. Apply narrow,
mandatory sanitization where the value commonly contains secrets, personal data,
or local filesystem identity. Sanitization affects only the Buildkite export copy;
a customer's other exporters continue to receive their original telemetry.
The stored Buildkite span is therefore a privacy-normalized projection of the
upstream OTel span, not a byte-for-byte archival copy.

The initial behavior is:

| Instrumentation data | Initial policy |
| --- | --- |
| HTTP and network semantic attributes | Preserve the attributes emitted by Ruby OTel, including method, status, destination, URL components, and connection details. |
| Database identity and operation attributes | Preserve attributes such as `db.system`, `db.operation`, database identity, and connection details. |
| SQL/CQL query text | Preserve query shape only after mandatory literal normalization. |
| Unsupported database query formats | Omit query text until a system-specific sanitizer is available; preserve the remaining operation attributes. |
| `db.query.summary` | Preserve when supplied; it is a useful lower-cardinality grouping key. |
| `error.type` and protocol/database status attributes | Preserve for failure classification and test diagnosis. |
| Attributes from other installed instrumentations | Preserve initially, then review using observed sensitivity, utility, cardinality, and storage cost. |

### Database query normalization

The installed Ruby instrumentation currently emits the experimental database
names `db.system`, `db.operation`, and `db.statement`. Keep those names rather
than rewriting customer telemetry. During the OTel semantic-convention migration,
also recognize the stable `db.system.name` and `db.query.text` attributes when
they are present.

Normalize both `db.statement` and `db.query.text` in the Buildkite export copy,
even if upstream instrumentation is configured to include raw SQL. String,
numeric, boolean, UUID, and comment values are replaced with `?` using the
OpenTelemetry SQL processor and the dialect selected from `db.system` or
`db.system.name`. For example:

```text
SELECT * FROM users WHERE email = 'person@example.com' AND id = 42
SELECT * FROM users WHERE email = ? AND id = ?
```

Statements that exceed the processor's safety limit produce only its safe
placeholder message. If normalization fails, omit that query attribute rather
than exporting the original value. `db.query.summary`, `db.operation`,
`db.operation.name`, and `error.type` do not contain query literals and pass
through unchanged when supplied.

`db.statement` and `db.query.text` are generic database attributes and may also
contain Redis commands, MongoDB documents, or other non-SQL formats. Do not pass
those values through the SQL processor and assume they are safe. Omit query text
for an unrecognized database system until a system-specific sanitizer is
implemented; retain its system, operation, duration, status, and other semantic
attributes.

### Suggested evolution after the initial release

Do not drop attributes solely because two fields appear similar in one sample.
Measure representative suites and actual product queries first. Then evolve the
policy in reviewable stages:

| Level | Intended use | Attribute policy |
| --- | --- | --- |
| **Initial: broad and normalized** | Maximize learning and test intelligence in the first release. | Preserve upstream Ruby OTel semantic attributes. Always normalize known-sensitive values such as SQL literals and absolute process command paths. |
| **Curated** | Future storage-efficient default based on evidence. | Keep attributes used by Test Engine features and investigations; canonicalize or remove fields proven redundant, low-value, or disproportionately high-cardinality. |
| **Extended/debug** | Explicit troubleshooting when normal instrumentation omits needed detail. | Allow reviewed opt-in attributes on a per-integration basis. Mandatory secret and personal-data sanitization still applies; this level does not provide a bypass. |

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
and preserves the emitted semantic attributes. The exporter enforces
basename-only `process.command` and normalizes both experimental `db.statement`
and stable `db.query.text` query attributes.

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
