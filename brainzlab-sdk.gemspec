# frozen_string_literal: true

require_relative "lib/brainzlab/version"

Gem::Specification.new do |spec|
  spec.name = "brainzlab-sdk"
  spec.version = BrainzLab::VERSION
  spec.authors = ["Brainz Lab"]
  spec.email = ["support@brainzlab.ai"]

  spec.summary = "Ruby SDK for Brainz Lab - Recall logging and Reflex error tracking"
  spec.description = "Official Ruby SDK for integrating with Brainz Lab services including Recall (structured logging) and Reflex (error tracking)"
  spec.homepage = "https://brainzlab.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/brainzlab/brainzlab-sdk-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/brainzlab/brainzlab-sdk-ruby/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir["{lib}/**/*", "LICENSE", "README.md", "CHANGELOG.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "concurrent-ruby", "~> 1.0"
  spec.add_dependency "logger"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
