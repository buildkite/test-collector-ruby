# Buildkite Collectors for Ruby

**DEPRECATION NOTICE**
Versions prior to 2.1.x are unsupported and will not work after mid-2023. Please upgrade to the latest version.

Official [Buildkite Test Engine](https://buildkite.com/platform/test-engine) collectors for Ruby test frameworks ✨

⚒ **Supported test frameworks:** RSpec, Minitest, Cucumber, and [more coming soon](https://github.com/buildkite/test-collector-ruby/issues?q=is%3Aissue+is%3Aopen+label%3A%22test+frameworks%22).

📦 **Supported CI systems:** Buildkite, GitHub Actions, CircleCI, Codeship, and others via the `BUILDKITE_ANALYTICS_*` environment variables.

## 👉 Installing

### Step 1

[Create a test suite](https://buildkite.com/docs/test-analytics), and copy the API token that it gives you.

Add the [`buildkite-test_collector`](https://rubygems.org/gems/buildkite-test_collector) gem:

```shell
gem install buildkite-test_collector
```

Or add this to your Gemfile’s test group:

```ruby
group :test do
  gem 'buildkite-test_collector'
end
```

### Step 2

#### RSpec

Add the following code to your RSpec setup file:

```ruby
# spec/spec_helper.rb
require 'buildkite/test_collector'
Buildkite::TestCollector.configure(hook: :rspec)
```

Run your tests locally:

```shell
BUILDKITE_ANALYTICS_TOKEN=xyz rspec
```

#### Minitest

Add the following code to your Minitest setup file:

```ruby
# test/test_helper.rb
require 'buildkite/test_collector'
Buildkite::TestCollector.configure(hook: :minitest)
```

Run your tests locally:

```shell
BUILDKITE_ANALYTICS_TOKEN=xyz rake
```

#### Cucumber

Add the following code to your Cucumber setup file:

```ruby
# features/support/env.rb
require 'buildkite/test_collector'
Buildkite::TestCollector.configure(hook: :cucumber)
```

Run your tests locally:

```shell
BUILDKITE_ANALYTICS_TOKEN=xyz cucumber
```

### Step 3

Add the `BUILDKITE_ANALYTICS_TOKEN` secret to your CI, push your changes to a branch, and open a pull request 🎉

### OpenTelemetry export (experimental)

RSpec suites can also send an OpenTelemetry trace per test execution to Buildkite,
showing what each test did and where it spent its time. Each trace is rooted in a
`test.execution` span naming the test, its file, and whether it passed.

This is still under development and everything here may change. It is off by
default, so opt in when you configure the collector:

```ruby
Buildkite::TestCollector.configure(hook: :rspec, otel_enabled: true)
```

If your suite already runs OpenTelemetry, we use your existing setup and your
instrumentation as it is. A non-`nil` `otel_instrumentations` selection is
ignored with a warning in that path. If the suite doesn't run OpenTelemetry, we
set one up and install the applicable curated HTTP and SQL instrumentation
(`net_http`, `pg`, `mysql2`, and `trilogy`). You can omit
`otel_instrumentations` completely to use those defaults. Set it only to select
an exact subset, add customer-supplied instrumentation to the defaults, or
export only root spans. See the
[OpenTelemetry guide](docs/opentelemetry.md#choosing-instrumentation) for the
available options.

The collector includes those four curated instrumentation gems instead of
`opentelemetry-instrumentation-all`. Optional instrumentation remains the
customer's Gemfile responsibility.

Before installing bundled instrumentation selected by symbol, the collector
checks its target for foreign patches and skips that instrumentation if it finds
one. Instrumentation passed by its registered name is an explicit customer
choice, so it is installed without this guard and its compatibility with other
patches is the customer's responsibility.

Export needs Ruby 3.3 or newer, which is what the OpenTelemetry gems require. On
older Rubies the option is accepted and does nothing.

Spans need `BUILDKITE_ANALYTICS_TOKEN` to be an agent OIDC token with the
`write_uploads` scope, from `buildkite-agent oidc request-token`. A suite API
token still uploads executions, but its spans are rejected.

Export failures never fail a test or block the normal Test Engine upload. See the
[OpenTelemetry guide](docs/opentelemetry.md) for what you get and how it
fits around an existing OpenTelemetry setup.

## More information

For more use cases such as custom tags, annotations, and span tracking, please visit our [official Ruby collector documentation](https://buildkite.com/docs/test-engine/ruby-collectors) for details.

## ⚒ Developing

After cloning the repository, install the dependencies:

```
bundle
```

And run the tests:

```
bundle exec rspec
```

Useful resources for developing collectors include the [Buildkite Test Engine docs](https://buildkite.com/docs/test-engine).

See [DESIGN.md](DESIGN.md) for an overview of the design of this gem.

## 👩‍💻 Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/buildkite/test-collector-ruby

## 🚀 Releasing

1. Bump the version in `version.rb` and run `bundle` to update the `Gemfile.lock`.
2. Update the CHANGELOG.md with your new version and a description of your changes.
3. Once your PR is merged to `main` git tag the merge commit and push:

```
git tag vX.X.X
git push origin vX.X.X
```
4. Visit the [release pipeline](https://buildkite.com/buildkite/test-collector-ruby-release) to unblock it and confirm the new version is pushed to rubygems.org
5. Create a [new release in github](https://github.com/buildkite/test-collector-ruby/releases).

## 📜 MIT License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
