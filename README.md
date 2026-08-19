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

Execution roots use a private AlwaysOn provider so a suite's sampling policy
cannot remove them. If the suite already runs OpenTelemetry, the collector
forwards its sampled spans created during a test execution without changing the
suite's provider, sampler, instrumentation, exporters, or lifecycle.

If the suite does not configure OpenTelemetry, the collector configures a global
provider for child spans and installs all applicable instrumentation registered
when the suite starts. The collector does not include instrumentation gems. Add
and explicitly require each one you want to use:

```ruby
# Gemfile
gem "opentelemetry-instrumentation-pg", require: false

# spec/spec_helper.rb
require "opentelemetry-instrumentation-pg"
require "buildkite/test_collector"

Buildkite::TestCollector.configure(hook: :rspec, otel_enabled: true)
```

Adding a gem to the Gemfile may auto-require it in applications that call
`Bundler.require`, but that is not guaranteed. An explicit `require` is the
recommended setup. To disable instrumentations and export only root
`test.execution` spans, set `otel_instrumentations: []`. Any other value is
reserved for a future release and disables span export with a warning,
regardless of who owns the provider. In suite-owned mode, a supported
`otel_instrumentations: []` selection is ignored with a warning. See the
[OpenTelemetry guide](docs/opentelemetry.md#choosing-instrumentation) for more.

Export needs Ruby 3.3 or newer, which is what the OpenTelemetry gems require. On
older Rubies the option is accepted and does nothing.

Spans need `BUILDKITE_ANALYTICS_TOKEN` to be an agent OIDC token with the
`write_uploads` scope, from `buildkite-agent oidc request-token`. A suite API
token still uploads executions, but its spans are rejected.

Export failures never fail a test or block the normal Test Engine upload. See the
[OpenTelemetry guide](docs/opentelemetry.md) for what you get and how it
fits around an existing OpenTelemetry setup.

### OTLP-only submission (experimental)

RSpec suites can go one step further and submit results *only* over OTLP, with
no JSON upload at all. Each test execution becomes one `test.execution` span
carrying the full execution details (name, location, result, failure reason and
backtrace), and Buildkite synthesizes the test execution from the span
server-side:

```ruby
Buildkite::TestCollector.configure(hook: :rspec, otel_only: true)
```

In this mode the collector's legacy machinery is switched off: nothing is
uploaded to `/v1/uploads`, and `Net::HTTP` and `Object` are left unpatched. The
gem's whole job is to configure OpenTelemetry so each test gets a suitable span:

- `Buildkite::TestCollector.annotate` adds a `test.annotation` event to the
  current span.
- `Buildkite::TestCollector.tag_execution` sets attributes on the test span.
- `tags:` given to `configure` become resource attributes on every span.
- Your code can also talk to OpenTelemetry directly — the collector configures
  the global tracer provider (unless your suite already has one), so
  `OpenTelemetry::Trace.current_span.set_attribute(...)` works during a test,
  and any instrumentation joins the test's trace.

`otel_only` is currently RSpec-only and needs Ruby 3.3+. It's an alternative to
`otel_enabled`; the two are mutually exclusive, and passing both (either value)
raises `ArgumentError`.

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
