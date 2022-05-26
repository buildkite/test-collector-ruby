# Buildkite Collectors for Ruby

Official Ruby-based [Buildkite Test Analytics](https://buildkite.com/test-analytics) collectors ✨


**Supported test frameworks:** RSpec, Minitest and more [coming soon](#roadmap).

**Supported CI systems:** Buildkite, GitHub Actions, CircleCI, Jenkins, and others via the `BUILDKITE_ANALYTICS_*` environment variables.

This gem collects data about your test suite's performance and reliability, and allows you to see trends and insights about your test suite over time ✨

## Installing

### RSpec

1) [Create a test suite](https://buildkite.com/docs/test-analytics), and copy the API token that it gives you.

1) Install [`buildkite-collector` gem](https://rubygems.org/gems/buildkite-collector) to your Gemfile in the `test` group:

```ruby
group :test do
  gem "rspec-buildkite-analytics"
end
```

2) Configure the RSpec Collector in `spec/spec_helper.rb`:

```ruby
require "buildkite/collector"

Buildkite::Collector.configure(ENV["BUILDKITE_ANALYTICS_TOKEN"])
```

3) Commit and push your changes to start analysing your tests

```sh
$ git checkout -b install-buildkite-test-analytics
$ git add .
$ git commit -m "Add Buildkite Test Analytics collector"
$ git push
```

4) Make sure that the [Test Analytics environment variables](https://buildkite.com/docs/test-analytics/integrations#integrating-with-rspec-environment-variables) are set so that the RSpec integration can use them in your Test Analytics dashboard.

## Debugging

To enable debugging output, set `BUILDKITE_ANALYTICS_DEBUG_ENABLED=true`.

## Roadmap

- [ ] Additional test frameworks (`Test::Unit`, Bacon, Cucumber)

## Developing

After cloning the repository, install the dependencies using Bundler:

```sh
$ bundle
```

You can run the tests for this library by executing:

```
$ bundle exec rspec
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/buildkite/collector-rb.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
