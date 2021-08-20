# frozen_string_literal: true

require "pty"
require "stringio"
require "rspec/buildkite/insights/uploader"

RSpec.describe "RSpec::Buildkite::Insights::Uploader" do
  EXAMPLE_DIR = File.expand_path("../../../example", __FILE__)

  def safe_pty(command, **pty_options)
    output = StringIO.new

    PTY.spawn(*command, **pty_options) do |r, w, pid|
      begin
        r.each_line { |line| output.puts(line) }
      rescue Errno::EIO
        # Command closed output, or exited
      ensure
        Process.wait pid
      end
    end

    output.string
  end

  # Returns a string contains the result of
  #   cd example && bundle exec rspec
  def execute_example_suite
    command = ["bundle exec rspec"]

    safe_pty(command, chdir: EXAMPLE_DIR)
  end

  it "make sure a suite can set up Insights" do
    result = execute_example_suite

    expect(result).to include "0 failures"
    expect(result).not_to include "An error occurred"
  end
end
