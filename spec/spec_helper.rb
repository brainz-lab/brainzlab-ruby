# frozen_string_literal: true

require 'bundler/setup'
require 'brainzlab'
require 'webmock/rspec'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before do
    BrainzLab.reset_configuration!
    BrainzLab.clear_context!
    WebMock.reset!

    # Stub all Recall logs to prevent background threads from making unexpected requests
    stub_request(:post, %r{recall\.brainzlab\.ai/api/v1/logs})
      .to_return(status: 201, body: '{"ingested": 1}')
  end
end
