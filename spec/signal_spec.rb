# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Signal do
  before do
    BrainzLab.configure do |config|
      config.secret_key = 'test_key'
      config.service = 'test-service'
      config.environment = 'test'
      config.host = 'test-host'
      config.signal_enabled = true
      config.signal_api_key = 'test_signal_key' # Set to skip auto-provisioning
    end

    described_class.reset!

    stub_request(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
      .to_return(status: 201, body: '{"id": "alert_123"}')

    stub_request(:post, 'https://signal.brainzlab.ai/api/v1/notifications')
      .to_return(status: 201, body: '{"id": "notification_123"}')

    stub_request(:post, 'https://signal.brainzlab.ai/api/v1/rules/trigger')
      .to_return(status: 201, body: '{"triggered": true}')
  end

  describe '.alert' do
    it 'sends an alert' do
      described_class.alert(
        'high_error_rate',
        'Error rate exceeded threshold',
        severity: :error,
        channels: %w[slack email],
        data: { rate: 15.5, threshold: 10 }
      )

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
        .with do |req|
          body = JSON.parse(req.body)
          body['type'] == 'alert' &&
            body['name'] == 'high_error_rate' &&
            body['message'] == 'Error rate exceeded threshold' &&
            body['severity'] == 'error' &&
            body['channels'] == %w[slack email] &&
            body['data']['rate'] == 15.5
        end)
    end

    it 'includes environment and service' do
      described_class.alert('test_alert', 'Test message')

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
        .with do |req|
          body = JSON.parse(req.body)
          body['environment'] == 'test' &&
            body['service'] == 'test-service' &&
            body['host'] == 'test-host'
        end)
    end

    it 'defaults to warning severity' do
      described_class.alert('test_alert', 'Test message')

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
        .with do |req|
          body = JSON.parse(req.body)
          body['severity'] == 'warning'
        end)
    end

    it 'includes context data' do
      BrainzLab.set_user(id: 123)
      BrainzLab.set_tags(version: '1.0')
      BrainzLab.set_context(deployment: 'production')

      described_class.alert('test_alert', 'Test message')

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
        .with do |req|
          body = JSON.parse(req.body)
          body['context']['user']['id'] == 123 &&
            body['context']['tags']['version'] == '1.0' &&
            body['context']['extra']['deployment'] == 'production'
        end)
    end

    it 'does nothing when signal is disabled' do
      BrainzLab.configuration.signal_enabled = false

      described_class.alert('test_alert', 'Test message')

      expect(WebMock).not_to have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
    end

    it 'supports different severity levels' do
      %i[info warning error critical].each do |severity|
        described_class.alert('test', 'message', severity: severity)

        expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
          .with do |req|
            body = JSON.parse(req.body)
            body['severity'] == severity.to_s
          end)

        WebMock.reset!
        stub_request(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
          .to_return(status: 201, body: '{"id": "alert_123"}')
      end
    end
  end

  describe '.notify' do
    it 'sends a notification to a single channel' do
      described_class.notify('slack', 'Deployment completed', title: 'Deploy Success')

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/notifications')
        .with do |req|
          body = JSON.parse(req.body)
          body['type'] == 'notification' &&
            body['channels'] == ['slack'] &&
            body['message'] == 'Deployment completed' &&
            body['title'] == 'Deploy Success'
        end)
    end

    it 'sends a notification to multiple channels' do
      described_class.notify(%w[slack email], 'System maintenance scheduled')

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/notifications')
        .with do |req|
          body = JSON.parse(req.body)
          body['channels'] == %w[slack email]
        end)
    end

    it 'includes additional data' do
      described_class.notify('webhook', 'Event triggered', data: { event_id: 'evt_123' })

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/notifications')
        .with do |req|
          body = JSON.parse(req.body)
          body['data']['event_id'] == 'evt_123'
        end)
    end

    it 'does nothing when signal is disabled' do
      BrainzLab.configuration.signal_enabled = false

      described_class.notify('slack', 'Test message')

      expect(WebMock).not_to have_requested(:post, 'https://signal.brainzlab.ai/api/v1/notifications')
    end
  end

  describe '.trigger' do
    it 'triggers a predefined alert rule' do
      described_class.trigger('disk_space_low', threshold: 90, current: 95)

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/rules/trigger')
        .with do |req|
          body = JSON.parse(req.body)
          body['type'] == 'trigger' &&
            body['rule'] == 'disk_space_low' &&
            body['context']['threshold'] == 90 &&
            body['context']['current'] == 95
        end)
    end

    it 'includes environment and service' do
      described_class.trigger('test_rule')

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/rules/trigger')
        .with do |req|
          body = JSON.parse(req.body)
          body['environment'] == 'test' &&
            body['service'] == 'test-service'
        end)
    end

    it 'does nothing when signal is disabled' do
      BrainzLab.configuration.signal_enabled = false

      described_class.trigger('test_rule')

      expect(WebMock).not_to have_requested(:post, 'https://signal.brainzlab.ai/api/v1/rules/trigger')
    end
  end

  describe '.test!' do
    it 'sends a test alert' do
      described_class.test!

      expect(WebMock).to(have_requested(:post, 'https://signal.brainzlab.ai/api/v1/alerts')
        .with do |req|
          body = JSON.parse(req.body)
          body['name'] == 'test_alert' &&
            body['message'].include?('test alert') &&
            body['severity'] == 'info' &&
            body['data']['test'] == true &&
            body['data']['sdk_version'] == BrainzLab::VERSION
        end)
    end
  end

  describe '.reset!' do
    it 'resets all signal state' do
      described_class.alert('test', 'message')

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
      expect(described_class.instance_variable_get(:@provisioner)).to be_nil
    end
  end
end
