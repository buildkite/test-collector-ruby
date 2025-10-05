# frozen_string_literal: true

RSpec.describe Buildkite::TestCollector::CodeOwners do
  subject { described_class.new(file_content.split("\n")) }

  let(:file_content) {
    <<~CODEOWNERS
      * @everyone
      /spec/models/ @model_team
      /config/ @ops @security
      /no_team_defined/
    CODEOWNERS
  }

  describe "#find_owner" do
    it "finds the owner" do
      expect(subject.find_rule("spec/foo_spec.rb").owners).to eq ["@everyone"]
      expect(subject.find_rule("spec/models/model_spec.rb").owners).to eq ["@model_team"]
      expect(subject.find_rule("config/database.yml").owners).to eq ["@ops", "@security"]

      expect(subject.find_rule("./spec/models/model_spec.rb").owners).to eq ["@model_team"]
      expect(subject.find_rule("./no_team_defined/model_spec.rb").owners).to eq []
    end
  end
end
