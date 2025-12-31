# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Beacon do
  before do
    BrainzLab.configure do |config|
      config.secret_key = 'test_key'
      config.service = 'test-service'
      config.environment = 'test'
      config.beacon_enabled = true
    end

    described_class.reset!

    stub_request(:get, 'https://beacon.brainzlab.ai/api/v1/monitors')
      .to_return(status: 200, body: '{"monitors": [{"id": "mon_123", "name": "API Health", "status": "up"}]}')

    stub_request(:get, %r{beacon\.brainzlab\.ai/api/v1/monitors/[^/]+$})
      .to_return(status: 200, body: '{"id": "mon_123", "name": "API Health", "status": "up", "uptime": 99.9}')

    stub_request(:post, 'https://beacon.brainzlab.ai/api/v1/monitors')
      .to_return(status: 201, body: '{"id": "mon_456", "name": "New Monitor"}')

    stub_request(:get, %r{beacon\.brainzlab\.ai/api/v1/incidents})
      .to_return(status: 200, body: '{"incidents": [{"id": "inc_123", "status": "investigating"}]}')

    stub_request(:get, 'https://beacon.brainzlab.ai/api/v1/status')
      .to_return(status: 200, body: '{"overall": "operational", "status": "up", "components": []}')
  end

  describe '.list' do
    it 'lists all monitors' do
      result = described_class.list

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq('API Health')
    end

    it 'returns empty array when beacon is disabled' do
      BrainzLab.configuration.beacon_enabled = false

      result = described_class.list

      expect(result).to eq([])
      expect(WebMock).not_to have_requested(:get, /beacon\.brainzlab\.ai/)
    end
  end

  describe '.get' do
    it 'gets a specific monitor' do
      result = described_class.get('mon_123')

      expect(result[:name]).to eq('API Health')
      expect(result[:uptime]).to eq(99.9)
    end
  end

  describe '.create_http_monitor' do
    it 'creates a new HTTP monitor' do
      result = described_class.create_http_monitor(
        'Database Check',
        'https://api.example.com/health',
        interval: 60
      )

      expect(result[:id]).to eq('mon_456')
      expect(WebMock).to(have_requested(:post, 'https://beacon.brainzlab.ai/api/v1/monitors')
        .with do |req|
          body = JSON.parse(req.body)
          body['name'] == 'Database Check' &&
            body['url'] == 'https://api.example.com/health' &&
            body['monitor_type'] == 'http'
        end)
    end
  end

  describe '.incidents' do
    it 'lists incidents' do
      result = described_class.incidents

      expect(result).to be_an(Array)
      expect(result.first[:status]).to eq('investigating')
    end

    it 'filters by status' do
      described_class.incidents(status: 'resolved')

      expect(WebMock).to have_requested(:get, 'https://beacon.brainzlab.ai/api/v1/incidents')
        .with(query: { 'status' => 'resolved' })
    end
  end

  describe '.status' do
    it 'gets overall status' do
      result = described_class.status

      expect(result[:overall]).to eq('operational')
    end
  end

  describe '.all_up?' do
    it 'returns true when all monitors are up' do
      result = described_class.all_up?

      expect(result).to be true
    end
  end

  describe '.reset!' do
    it 'resets all beacon state' do
      described_class.list

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end
end
