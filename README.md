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

Version 3 requires Ruby 3.3 or newer for every supported test framework. Projects
on older Ruby versions should continue using the latest 2.x release.

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

### Experimental OpenTelemetry export

Ruby 3.3+ RSpec suites can opt into the experimental OpenTelemetry integration by
setting an authenticated Buildkite OTLP endpoint:

```shell
BUILDKITE_ANALYTICS_OTLP_ENDPOINT=https://example.com/v1/traces rspec
```

The integration is additive: exporter failures do not fail tests or interrupt
the normal Test Engine execution upload. See the
[architecture](docs/opentelemetry-architecture.md) for its scope and contracts.

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
