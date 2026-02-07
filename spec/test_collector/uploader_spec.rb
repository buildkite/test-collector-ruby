# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::Uploader do
  let(:http_client_double) { instance_double(Buildkite::TestCollector::HTTPClient) }
  let(:api_token) { 'fake_api_token' }

  before do
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new).and_return(http_client_double)
    allow(Buildkite::TestCollector).to receive(:api_token).and_return(api_token)
    allow(Buildkite::TestCollector).to receive(:url).and_return('https://fake-url.com')
  end

  describe '.upload' do
    it 'posts data to the HTTP client' do
      expect(http_client_double).to receive(:post_upload).with(
        data: [{some: 'data'}],
        run_env: hash_including("collector" => "ruby-buildkite-test_collector"),
        tags: {},
      )

      future = Buildkite::TestCollector::Uploader.upload([{some: 'data'}])
      future.wait if future
    end

    context 'when there is RuntimeError' do
      before do
        allow(http_client_double).to receive(:post_upload).and_raise(RuntimeError)
        allow($stderr).to receive(:puts)
      end

      it 'logs an error message' do
        expect($stderr).to receive(:puts).with(include("experienced an error when sending your data"))

        future = Buildkite::TestCollector::Uploader.upload([{some: 'data'}])
        future.wait if future
      end
    end
  end
end
