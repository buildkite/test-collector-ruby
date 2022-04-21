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

Set the `BUILDKITE_ANALYTICS_KEY` environment variable, either via the command line or using a secure method like Rails custom credentials (https://edgeguides.rubyonrails.org/security.html#custom-credentials).

Please avoid committing your API key to your repository for security reasons.


Configure your API key:
```ruby
RSpec::Buildkite::Analytics.configure(token: ENV["BUILDKITE_ANALYTICS_KEY"])
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

## Contributing
Bug reports and pull requests are welcome on GitHub at https://github.com/buildkite/rspec-buildkite-analytics.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
