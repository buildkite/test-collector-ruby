# Design

## Threads

The Buildkite ruby collector uses threads to send data to the Upload API in the background. When the test suite has finished running, the collector waits UPLOAD_SESSION_TIMEOUT seconds for the Upload API requests to finish before exiting.

## Data

Trace data is stored in spans. See [Buildkite::TestCollector::Tracer](lib/buildkite/test_collector/tracer.rb) for more information.
