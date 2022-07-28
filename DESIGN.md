# Design

## Threads

The Buildkite ruby collector uses websockets and ActionCable to send and
receive data with Buildkite. Execution information starts transmitting as soon
as possible, without waiting for the test suite to finish running.

This gem uses 3 ruby threads:

* main thread: acts as the producer. It collects span data from the
  test suite and enqueues it into the send queue.
* write thread: acts as the consumer. Removes data from the send queue and
  sends it to Buildkite.
* read thread: receives and processes messages from Buildkite.

## Data

Trace data is stored in spans. See [Buildkite::TestCollector::Tracer](lib/buildkite/test_collector/tracer.rb) for more information.
