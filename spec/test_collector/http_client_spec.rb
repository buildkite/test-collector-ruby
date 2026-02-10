# frozen_string_literal: true

require "ostruct"

RSpec.describe Buildkite::TestCollector::HTTPClient do
  subject do
    Buildkite::TestCollector::HTTPClient.new(
      url: "http://buildkite.localhost/v1/uploads",
      api_token: "thetoken",
    )
  end

  let(:example_group) { OpenStruct.new(metadata: { full_description: "i love to eat pies" }) }
  let(:execution_result) { OpenStruct.new(status: :passed) }
  let(:example) do
    OpenStruct.new(
      example_group: example_group,
      description: "mince and cheese",
      id: "12",
      location: "123 Pie St",
      execution_result: execution_result,
      metadata: { shared_group_inclusion_backtrace: [] }
    )
  end

  let(:trace) do
    t = Buildkite::TestCollector::RSpecPlugin::Trace.new(example, history: "pie lore")
    t.result = "passed"
    t
  end

  let(:http_double) { double("Net::HTTP_double") }
  let(:post_double) { double("Net::HTTP::Post") }
  let(:response) { double("Net::HTTPResponse") }

  let(:request_body) do
    {
      "run_env": {
        "key": "build-123",
      },
      "tags": {
        "language.name" => "ruby"
      },
      "format": "json",
      "data": [
        {
          "scope": "i love to eat pies",
          "name": "mince and cheese",
          "location": "123 Pie St",
          "result": "passed",
          "failure_expanded": [],
          "history": "pie lore"
        }
      ]
    }.to_json
  end



  let(:run_env) { {"key" => "build-123"} }
  let(:tags) { {"language.name" => "ruby"} }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http_double)
    allow(http_double).to receive(:use_ssl=)

    allow(Net::HTTP::Post).to receive(:new).with("/v1/uploads", {
      "Authorization" => "Token token=\"thetoken\"",
      "Content-Encoding" => "gzip",
      "Content-Type" => "application/json",
    }).and_return(post_double)
  end

  describe "#post_upload" do
    it "sends the right data" do
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)

      expect(post_double).to receive(:body=) do |body|
        decompressed = Zlib::GzipReader.new(StringIO.new(body)).read
        expect(decompressed).to eq(request_body)
      end

      expect(http_double).to receive(:request).with(post_double).and_return(response)

      subject.post_upload(
        data: [trace],
        run_env: run_env,
        tags: tags,
      )
    end

    it "throw error in a server error" do
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(response).to receive(:code).and_return("500")
      allow(response).to receive(:message).and_return("Internal Server Error")

      expect(post_double).to receive(:body=) do |body|
        decompressed = Zlib::GzipReader.new(StringIO.new(body)).read
        expect(decompressed).to eq(request_body)
      end

      expect(http_double).to receive(:request).with(post_double).and_return(response)

      expect {
        subject.post_upload(
          data: [trace],
          run_env: run_env,
          tags: tags,
        )
      }.to raise_error(RuntimeError, "HTTP Request Failed: 500 Internal Server Error")
    end
  end
end
