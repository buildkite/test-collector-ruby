# RSpec Buildkite Insights

An RSpec gem to gather insights from your Test Suite.

## Installation

```ruby
group :test do
  gem "rspec-buildkite-insights", require: false
end
```

Get your Suite Key from Buildkite Test Insights then add the following to your `spec/spec_helper.rb`:

```ruby
if ENV["CI"]
  require "rspec/buildkite/insights"
  RSpec::Buildkite::Insights.configure(token: "YOUR SUITE KEY")
end
```

Modify allowed host from VCR / WebMock if necessary.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `bin/rake test` to run the tests.

## Collecting insights data locally

If you want to run your tests on your local development environment and see the test data files that it generates, pass in a BUILDKITE_INSIGHTS_TOKEN with a value that includes "local", i.e.

`BUILDKITE_INSIGHTS_TOKEN=local rspec spec`

The files will be available at ./tmp

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/buildkite/rspec-buildkite-insights. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the RSpec Buildkite Insights project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/buildkite/rspec-buildkite-insights/blob/main/CODE_OF_CONDUCT.md).
