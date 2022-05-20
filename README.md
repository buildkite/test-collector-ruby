# RSpec Buildkite Analytics

This gem collects data about your test suite's performance and reliability, and allows you to see trends and insights about your test suite over time ✨

## Installation

1. Create a new branch

```sh
git checkout -b install-buildkite-test-analytics
```

2. Add the `rspec-buildkite-analytics` gem to your `Gemfile` in the `test` group

```ruby
group :test do
  gem "rspec-buildkite-analytics"
end
```

3. Run `bundle` to install the gem and update your `Gemfile.lock`

```sh
$ bundle
```

4. Add the Test Analytics code to your application in `spec/spec_helper.rb`, and [set the environment variable securely](https://buildkite.com/docs/pipelines/secrets) on your agent or agents.

```ruby
require "buildkite/collector"

Buildkite::Collector.configure(ENV["BUILDKITE_ANALYTICS_TOKEN"])
```

5. Commit and push your changes to start analysing your tests

```sh
$ git add .
$ git commit -m "Add Buildkite Test Analytics client"
$ git push
```

6. Make sure that the [Test Analytics environment variables](https://buildkite.com/docs/test-analytics/integrations#integrating-with-rspec-environment-variables) are set so that the RSpec integration can use them in your Test Analytics dashboard.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/buildkite/rspec-buildkite-analytics.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
