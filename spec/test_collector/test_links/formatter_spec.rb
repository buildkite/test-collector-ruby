# frozen_string_literal: true

require 'buildkite/test_collector/test_links_plugin/formatter'

RSpec.describe Buildkite::TestCollector::TestLinksPlugin::Formatter do
  let(:passed_example) { fake_example(status: :passed) }
  let(:http_client) { double('Buildkite::TestCollector::HTTPClient') }
  let(:suite_url) { 'https://example.com/suite/12345' }
  let(:response) { { suite_url: suite_url }.to_json }
  let(:io) { StringIO.new }
  let(:formatter) { Buildkite::TestCollector::TestLinksPlugin::Formatter.new(io) }

  before do
    allow(Buildkite::TestCollector::HTTPClient).to receive(:new).and_return(http_client)

    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: 'fake_token',
      url: 'http://fake.buildkite.localhost/v1/uploads'
    )
  end

  after do
    reset_io(io)
  end

  context 'when tests have failed' do
    let!(:failed_example) { fake_example(status: :failed) }
    let!(:notification) do
      double('RSpec::Core::Notifications::SummaryNotification', examples: [passed_example], failed_examples: [failed_example])
    end

    context 'there is no token' do
      before do
        Buildkite::TestCollector.configure(hook: :rspec, token: nil, url: 'http://fake.buildkite.localhost/v1/uploads')
      end

      it 'does not render summary' do
        formatter.dump_failures(notification)
        expect(io.string.strip).to be_empty
      end

      it 'does not request metadata' do
        formatter.dump_failures(notification)
        expect(Buildkite::TestCollector::HTTPClient).not_to receive(:new)
      end
    end

    context 'fetch_metadata does not return a suite_url' do
      it 'does not render summary' do
        allow(http_client).to receive(:metadata)
                          .and_return(OpenStruct.new(code: '200', body: { suite_url: nil }.to_json))
        formatter.dump_failures(notification)

        expect(io.string.strip).to be_empty
      end
    end

    context 'fetch_metadata throws an error' do
      it 'does not render summary' do
        allow(http_client).to receive(:metadata).and_return(StandardError)
        formatter.dump_failures(notification)

        expect(io.string.strip).to be_empty
      end
    end

    context 'fetch_metadata has a non 200 response' do
      it 'does not render summary' do
        allow(http_client).to receive(:metadata).and_return(OpenStruct.new(code: '500', body: response))
        formatter.dump_failures(notification)

        # dump_failures should not out put anything
        expect(io.string.strip).to be_empty
      end
    end

    context 'fetch_metadata is successful and a token exists' do
      it 'renders summary' do
        scope = failed_example.full_description
        name = failed_example.description
        scope_name_digest = Digest::SHA256.hexdigest(scope + name)

        allow(http_client).to receive(:metadata).and_return(OpenStruct.new(code: '200', body: response))
        formatter.dump_failures(notification)

        expect(io.string.strip).to include('Test Analytics failures:')
        expect(io.string.strip).to include("#{suite_url}/tests/#{scope_name_digest}")
        expect(io.string.strip).to include("#{scope} #{name}")
      end
    end
  end

  context 'when all tests passed' do
    let!(:notification) do
      double('RSpec::Core::Notifications::SummaryNotification', examples: [passed_example], failed_examples: [])
    end

    before do
      formatter.dump_failures(notification)
    end

    it 'does not render summary' do
      expect(io.string.strip).to be_empty
    end

    it 'does not request metadata' do
      expect(Buildkite::TestCollector::HTTPClient).not_to receive(:new)
    end
  end
end
