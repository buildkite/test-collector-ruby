# frozen_string_literal: true

require 'buildkite/test_collector/test_links_plugin/reporter'

RSpec.describe Buildkite::TestCollector::TestLinksPlugin::Reporter do
  let(:example_group) { OpenStruct.new(metadata: { full_description: 'i love to eat pies' }) }
  let(:execution_result) { OpenStruct.new(status: :failed) }
  let(:example) do
    OpenStruct.new(
      example_group: example_group,
      description: 'mince and cheese',
      execution_result: execution_result
    )
  end

  let(:suite_url) { 'https://example.com/suite/12345' }
  let(:response) { OpenStruct.new(body: { suite_url: suite_url }.to_json) }

  it 'test reporter works with only passed examples' do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: 'fake',
      url: 'http://fake.buildkite.localhost/v1/uploads'
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::TestLinksPlugin::Reporter.new(io)
    a_example = fake_example(status: :passed)
    trace = fake_trace(a_example)
    allow(Buildkite::TestCollector.uploader).to receive(:traces) { trace }
    notification = RSpec::Core::Notifications::ExampleNotification.for(a_example)

    reporter.dump_summary(notification)

    expect(io.string.strip).to be_empty

    reset_io(io)
  end

  it 'test reporter works with a failed example' do
    Buildkite::TestCollector.configure(
      hook: :rspec,
      token: 'fake',
      url: 'http://fake.buildkite.localhost/v1/uploads'
    )
    io = StringIO.new
    reporter = Buildkite::TestCollector::TestLinksPlugin::Reporter.new(io)
    scope = example.example_group.metadata[:full_description].to_s
    name = example.description.to_s

    scope_name_digest = Digest::SHA256.hexdigest(scope + name)

    allow(Buildkite::TestCollector.uploader).to receive(:response).and_return(response)
    allow(reporter).to receive(:generate_scope_name_digest).and_return(scope_name_digest)
    notification = RSpec::Core::Notifications::ExampleNotification.for(example)

    reporter.example_failed(notification)
    reporter.dump_summary(notification)

    # Displays the summary title
    expect(io.string.strip).to include('Test Analytics failures:')

    # Displays a test link
    expect(io.string.strip).to include("#{suite_url}/tests/#{scope_name_digest}")

    # Displays a test name
    expect(io.string.strip).to include("#{scope} #{name}")

    reset_io(io)
  end
end
