# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::Tracer do
  subject(:tracer) { Buildkite::TestCollector::Tracer.new(min_seconds: min_seconds) }
  let(:min_seconds) { nil }

  it "can produce an empty :top span" do
    history = tracer.finalize.history

    expect(history).to match({
      section: :top,
      start_at: Float,
      end_at: Float,
      duration: history[:end_at] - history[:start_at],
      detail: {},
      children: [],
    })
  end

  it "can produce trace spans with enter/leave or backfill" do
    begin
      tracer.enter(:hello, recipient: :world)
    ensure
      tracer.leave
    end

    tracer.backfill(:sql, 12.34, query: "SELECT hello FROM world")

    begin
      tracer.enter(:http, url: "https://example.com/")
    ensure
      tracer.leave
    end

    history = tracer.finalize.history

    expect(history).to match({
      section: :top,
      start_at: Float,
      end_at: Float,
      duration: history[:end_at] - history[:start_at],
      detail: {},
      children: [
        {
          section: :hello,
          start_at: Float,
          end_at: Float,
          duration: Float,
          detail: {recipient: :world},
          children: []
        },
        {
          section: :sql,
          start_at: Float,
          end_at: Float,
          duration: Float,
          detail: {query: "SELECT hello FROM world"},
          children: []
        },
        {
          section: :http,
          start_at: Float,
          end_at: Float,
          duration: Float,
          detail: {url: "https://example.com/"},
          children: []
        },
      ],
    })
  end

  context "with mocked MonotonicTime" do
    before do
      allow(Buildkite::TestCollector::Tracer::MonotonicTime).to receive(:call) do
        monotonic_time_queue.shift || raise("monotonic_time_queue empty")
      end
    end
    let(:monotonic_time_queue) { [] }

    it "produces expected timing for :top span" do
      monotonic_time_queue << 11.1 # top start
      monotonic_time_queue << 12.2 # top end

      history = tracer.finalize.history

      expect(history).to match({
        section: :top,
        start_at: 11.1,
        end_at: 12.2,
        duration: be_within(0.001).of(1.1),
        detail: {},
        children: [],
      })
    end

    describe "filtering traces by min_seconds" do
      let(:min_seconds) { 2.0 }

      it "can filter traces by duration" do
        monotonic_time_queue << 10.0
        tracer

        monotonic_time_queue << 20.0
        tracer.enter(:fast_enter_leave)
        monotonic_time_queue << 20.1
        tracer.leave

        monotonic_time_queue << 21.0
        tracer.enter(:slow_enter_leave)
        monotonic_time_queue << 25.0
        tracer.leave

        # skipped by #backfill: monotonic_time_queue << 30.2
        tracer.backfill(:fast_backfill, 0.2)

        monotonic_time_queue << 43.5
        tracer.backfill(:slow_backfill, 3.5)

        monotonic_time_queue << 50.0
        history = tracer.finalize.history

        expect(history[:start_at]).to eq(10.0)
        expect(history[:end_at]).to eq(50.0)
        expect(history[:duration]).to be_within(0.001).of(40.0)

        expect(history[:children]).to match([
          {
            section: :slow_enter_leave,
            start_at: 21.0,
            end_at: 25.0,
            duration: be_within(0.001).of(4.0),
            detail: {},
            children: [],
          },
          {
            section: :slow_backfill,
            start_at: be_within(0.001).of(40.0),
            end_at: 43.5,
            duration: be_within(0.001).of(3.5),
            detail: {},
            children: [],
          },
        ])
      end
    end
  end
end
