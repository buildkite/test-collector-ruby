# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::Session do
  subject { Buildkite::TestCollector::Session.new }

  let(:data) do
    {
      "test-1": "test-1-data",
      "test-2": "test-2-data",
      "test-3": "test-3-data",
      "test-4": "test-4-data",
      "test-5": "test-5-data",
    }
  end

  before do
    Buildkite::TestCollector.uploader = Buildkite::TestCollector::Uploader
    data.each { |k, v| Buildkite::TestCollector.uploader.traces[k] = v }
    Buildkite::TestCollector.batch_size = 5
  end

  describe "#add_example_to_send_queue" do
    it "adds the example and sends only when batch size is reached" do
      expect(Buildkite::TestCollector::Uploader).to receive(:upload).once.with(data.values)

      subject.add_example_to_send_queue(:"test-1")
      subject.add_example_to_send_queue(:"test-2")
      subject.add_example_to_send_queue(:"test-3")
      subject.add_example_to_send_queue(:"test-4")
      subject.add_example_to_send_queue(:"test-5")
    end
  end

  describe "#send_remaining_data" do
    it "sends through remaining examples even when batch size is not reach" do
      expect(Buildkite::TestCollector::Uploader).to receive(:upload).once.with(data.reject { |k,v| k == :"test-5"}.values)

      subject.add_example_to_send_queue(:"test-1")
      subject.add_example_to_send_queue(:"test-2")
      subject.add_example_to_send_queue(:"test-3")
      subject.add_example_to_send_queue(:"test-4")

      subject.send_remaining_data
    end

    it "limits upload batch size to UPLOAD_API_MAX_RESULTS" do
      stub_const("Buildkite::TestCollector::Session::UPLOAD_API_MAX_RESULTS", 1)

      expect(Buildkite::TestCollector::Uploader).to receive(:upload).once.with(["test-1-data"])
      expect(Buildkite::TestCollector::Uploader).to receive(:upload).once.with(["test-2-data"])

      subject.add_example_to_send_queue(:"test-1")
      subject.add_example_to_send_queue(:"test-2")

      subject.send_remaining_data
    end
  end

  describe "#close" do
    let(:slow_future) { Concurrent::Promises.future { sleep(1) } }

    it "does not block waiting for slow uploads beyond session timeout" do
      stub_const("Buildkite::TestCollector::Session::UPLOAD_SESSION_TIMEOUT", 0.1)

      expect(Buildkite::TestCollector::Uploader).to receive(:upload).and_return(slow_future)

      subject.add_example_to_send_queue(:"test-1")

      subject.send_remaining_data

      start_time = Time.now
      subject.close
      elapsed_time = Time.now - start_time
      expect(elapsed_time).to be < 0.2
    end
  end
end
