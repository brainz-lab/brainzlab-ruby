# frozen_string_literal: true

require "bundler/setup"
require "brainzlab"
require "webmock/rspec"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    BrainzLab.reset_configuration!
    BrainzLab.clear_context!
    WebMock.reset!
  end
end
