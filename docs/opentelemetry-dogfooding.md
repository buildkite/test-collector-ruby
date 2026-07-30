# OpenTelemetry dogfooding plan

## Goal

Run the experimental Ruby collector against representative Buildkite test suites
to decide whether test-scoped OpenTelemetry traces provide useful, safe, and
operationally affordable debugging context.

This is an evidence-gathering exercise, not a production rollout. The
[architecture](opentelemetry-architecture.md) defines the contracts the test must
preserve.

## What we want to prove

1. **Correlation works end to end.** A Test Engine execution can be joined to its
   `test.execution` span, and every stored span receives the receiver-derived
   canonical run ID.
2. **Trace structure is useful.** HTTP, database, cache, and other synchronous
   work appears beneath the correct execution without copying Buildkite IDs onto
   child spans.
3. **The metadata is useful and safe.** Default instrumentation attributes help
   explain slow or failed tests without exposing credentials, raw request bodies,
   or sensitive query values. Source paths should match the existing execution
   upload and its configured `location_prefix`.
4. **Customer telemetry ownership remains intact.** Existing providers,
   resources, processors, sampling, flushing, and shutdown remain customer-owned.
   Because the provider is shared, customer exporters may also observe the new
   spans; dogfooding should measure and document that effect.
5. **The cost is acceptable.** Span volume, payload size, test runtime overhead,
   receiver load, storage growth, and query latency are understood well enough to
   choose production defaults.
6. **Failure remains fail-open.** Invalid configuration, rejected run identity,
   unavailable endpoints, and exporter failures do not affect tests or execution
   uploads.

## Test setup

Use at least two Ruby 3.3+ RSpec suites:

- a small service with HTTP and database activity for trace inspection; and
- a larger suite with parallel workers and realistic test volume for cost and
  lifecycle measurements.

At least one suite should already configure OpenTelemetry with its own service
resource and exporter. Run a control build without collector OTLP export, then an
experimental build from the same revision with:

```shell
BUILDKITE_ANALYTICS_OTLP_ENDPOINT=<authenticated Buildkite OTLP endpoint>
```

Use a dedicated Test Engine suite and non-production telemetry destination where
possible. Record collector, Ruby, RSpec, OTel dependency, receiver, and ingestion
versions with each run.

## Scenarios and evidence

| Scenario | Evidence to collect | Expected result |
| --- | --- | --- |
| Passing, failing, and skipped examples | Execution record and root span | Correct result mapping; one sampled root per execution. |
| HTTP, SQL, Redis, and other in-process work | Trace trees and span attributes | Synchronous work is parented correctly; useful semantic attributes survive. |
| Shared examples and `location_prefix` | Source fields in both paths | File and line identity agree with the execution upload. |
| Execution tags added inside a test | Root and child attributes | Tags appear on the root only and match the execution record. |
| Existing customer provider/exporter | Customer and Buildkite exports | Customer resource is unchanged; Buildkite resource attributes exist only in Buildkite's export. |
| `always_off` and ratio sampling | Execution records and exported roots | Unsampled executions have no dangling `external_id`; sampled traces correlate. |
| Invalid and missing run keys | Test result, execution upload, collector warning | OTel disables cleanly while normal collection succeeds. |
| Receiver rejection or unavailable endpoint | Test status, warnings, upload result | Tests and execution uploads are unaffected. |
| Large and parallel suites | Flush completion and span counts | Normal shutdown exports the final batch without hanging or shutting down customer telemetry. |
| Repeated/retried builds | Canonical run IDs | Receiver derivation is stable within a suite and isolated across suites. |

For each sampled trace, verify the complete contract:

```text
OTLP header Buildkite-Test-Run-Key
  == resource["buildkite.test.run.key"]

receiver(suite identity, raw run key)
  == Kafka["Buildkite-Test-Run-ID"]
  == stored span.run_id

execution.external_id
  == root["execution.externalId"]
```

Also confirm that a forged resource key cannot select another suite's run and
that ingestion rejects disagreement between the resource key and canonical Kafka
run ID.

## Measurements

Compare control and experimental builds for:

- wall-clock test duration and CPU/memory usage;
- spans per execution and spans per build;
- OTLP requests, retries, failures, compressed bytes, and flush duration;
- receiver rejection rate and ingestion verification failures;
- stored bytes per span and per execution; and
- latency for the product queries the traces are intended to support.

Review representative values for URLs, database statements, cache commands,
errors, process metadata, and execution tags. Record any sensitive, redundant,
high-cardinality, or low-value attributes rather than immediately adding ad hoc
collector filtering.

## Exit criteria

Dogfooding is successful when:

- correlation and suite isolation hold for all sampled traces;
- no tested failure mode breaks tests or normal execution uploads;
- customer provider/resource ownership and lifecycle are unchanged, with any new
  spans visible to customer exporters understood;
- trace trees materially improve at least one real slow-test or failure
  investigation;
- no unexpected sensitive values are observed under default instrumentation;
- normal shutdown exports reliably at representative volume; and
- measured overhead and storage cost support a concrete production proposal.

If any identity, tenancy, customer-telemetry, or sensitive-data invariant fails,
stop the experiment and fix it before expanding the test. Other outcomes should
be captured as evidence for follow-up decisions on instrumentation scope,
attribute policy, limits, sampling, and framework support.
