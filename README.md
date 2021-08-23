# RSpec Buildkite Analytics

This gem collects data about your test suite's performance and reliability, and allows you to see trends and insights about your test suite over time ✨

## Installation

Add the gem to your Gemfile:

```ruby
group :test do
  # ...
  gem "rspec-buildkite-analytics"
end
```

Configure your API key:
```ruby
RSpec::Buildkite::Analytics.configure do |config|
  config.suite_key = "........"
  # other config
end
```

Run bundler to install the gem and update your `Gemfile.lock`:
```
$ bundle
```

Lastly, commit and push your changes to start analysing your tests:
```
$ git commit -m "Add Buildkite Test Analytics client"
$ git push
```

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
