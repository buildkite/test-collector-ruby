# Buildkite Collectors for Ruby

Official [Buildkite Test Analytics](https://buildkite.com/test-analytics) collectors for Ruby test frameworks ✨

⚒ **Supported test frameworks:** RSpec, Minitest, and [more coming soon](https://github.com/buildkite/test-collector-ruby/issues?q=is%3Aissue+is%3Aopen+label%3A%22test+frameworks%22).

📦 **Supported CI systems:** Buildkite, GitHub Actions, CircleCI, and others via the `BUILDKITE_ANALYTICS_*` environment variables.

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

### Step 3

Add the `BUILDKITE_ANALYTICS_TOKEN` secret to your CI, push your changes to a branch, and open a pull request 🎉

```bash
git checkout -b add-buildkite-test-analytics
git commit -am "Add Buildkite Test Analytics"
git push origin add-buildkite-test-analytics
```

## 🗨️ Annotations

This gem allows adding custom annotations to the span data sent to Buildkite using the [.annotate](https://github.com/buildkite/test-collector-ruby/blob/d9fe11341e4aa470e766febee38124b644572360/lib/buildkite/test_collector.rb#L64) method. For example:

```ruby
Buildkite::TestCollector.annotate("User logged in successfully")
```

This is particularly useful for tests that generate a lot of span data such as system/feature tests.

## 🏷️ Tagging duplicate test executions with a prefix/suffix

For builds that execute the same test multiple times - such as when running the same test suite against multiple versions of ruby/rails - it's possible to tag each test execution with a prefix/suffix. This prefix/suffix is displayed for each execution on the test show page to differentiate the build environment. The prefix/suffix is specified using these environment variables:

```
BUILDKITE_ANALYTICS_EXECUTION_NAME_PREFIX
BUILDKITE_ANALYTICS_EXECUTION_NAME_SUFFIX
```

## 🔍 Debugging

To enable debugging output, set the `BUILDKITE_ANALYTICS_DEBUG_ENABLED` environment variable to `true`.

## 🔜 Roadmap

See the [GitHub 'enhancement' issues](https://github.com/buildkite/test-collector-ruby/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement) for planned features. Pull requests are always welcome, and we’ll give you feedback and guidance if you choose to contribute 💚

## ⚒ Developing

After cloning the repository, install the dependencies:

```
bundle
```

And run the tests:

```
bundle exec rspec
```

Useful resources for developing collectors include the [Buildkite Test Analytics docs](https://buildkite.com/docs/test-analytics).

See [DESIGN.md](DESIGN.md) for an overview of the design of this gem.

## 👩‍💻 Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/buildkite/test-collector-ruby

## 🚀 Releasing

1. Bump the version in `version.rb` and run `bundle` to update the `Gemfile.lock`.
1. Update the CHANGELOG.md with your new version and a description of your changes.
1. Git tag your changes and push
```
git tag v.x.x.x
git push --tags
```
Once your PR is merged to `main`:

1. Run `rake release` from `main`.
1. Create a [new release in github](https://github.com/buildkite/test-collector-ruby/releases).

## 📜 MIT License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
