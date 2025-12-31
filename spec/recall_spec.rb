# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Recall do
  before do
    BrainzLab.configure do |config|
      config.secret_key = 'test_key'
      config.service = 'test-service'
      config.environment = 'test'
    end

    stub_request(:post, 'https://recall.brainzlab.ai/api/v1/logs')
      .to_return(status: 201, body: '{"ingested": 1}')
  end

  describe '.info' do
    it 'logs an info message' do
      described_class.info('Test message', user_id: 123)
      described_class.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'info' &&
            log['message'] == 'Test message' &&
            log['data']['user_id'] == 123
        end)
    end
  end

  describe '.error' do
    it 'logs an error message' do
      described_class.error('Something failed', error: 'timeout')
      described_class.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'error' &&
            log['message'] == 'Something failed'
        end)
    end
  end

  describe '.time' do
    it 'logs with duration' do
      result = described_class.time('operation') { 42 }
      described_class.flush

      expect(result).to eq(42)
      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['message'].include?('operation') &&
            log['data']['duration_ms'].is_a?(Numeric)
        end)
    end
  end

  describe 'level filtering' do
    it 'respects min level setting' do
      BrainzLab.configuration.recall_min_level = :warn

      described_class.debug('Debug message')
      described_class.info('Info message')
      described_class.warn('Warn message')
      described_class.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].size == 1 &&
            body['logs'].first['level'] == 'warn'
        end)
    end
  end

  describe 'data scrubbing' do
    it 'scrubs sensitive fields' do
      described_class.info('User login', password: 'secret123', username: 'test')
      described_class.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          data = body['logs'].first['data']
          data['password'] == '[FILTERED]' &&
            data['username'] == 'test'
        end)
    end
  end

  describe 'context integration' do
    it 'includes context in logs' do
      BrainzLab.set_user(id: 456)
      BrainzLab.set_context(deployment: 'v2')

      described_class.info('With context')
      described_class.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          data = body['logs'].first['data']
          data['user']['id'] == 456 &&
            data['deployment'] == 'v2'
        end)
    end
  end
end
