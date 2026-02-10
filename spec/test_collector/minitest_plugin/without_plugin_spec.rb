# frozen_string_literal: true

require "minitest"

RSpec.describe "don’t break minitest when the plugin isn’t loaded" do
  describe "running minitest" do
    it "should not raise an error" do
      expect { Minitest.run }.not_to raise_error
    end
  end
end
