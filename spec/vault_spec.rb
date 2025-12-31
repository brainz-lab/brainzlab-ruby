# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Vault do
  before do
    BrainzLab.configure do |config|
      config.secret_key = 'test_key'
      config.service = 'test-service'
      config.environment = 'test'
      config.vault_enabled = true
      config.vault_cache_enabled = false
    end

    described_class.reset!

    stub_request(:get, %r{vault\.brainzlab\.ai/api/v1/secrets/.*})
      .to_return(status: 200, body: '{"key": "database_url", "value": "postgres://localhost/db", "version": 1}')

    stub_request(:post, 'https://vault.brainzlab.ai/api/v1/secrets')
      .to_return(status: 201, body: '{"key": "api_key", "version": 1}')

    stub_request(:delete, %r{vault\.brainzlab\.ai/api/v1/secrets/.*})
      .to_return(status: 200, body: '{}')

    stub_request(:get, 'https://vault.brainzlab.ai/api/v1/secrets')
      .to_return(status: 200, body: '{"secrets": [{"key": "database_url"}, {"key": "api_key"}]}')

    stub_request(:get, %r{vault\.brainzlab\.ai/api/v1/sync/export})
      .to_return(status: 200, body: '{"secrets": {"database_url": "postgres://localhost/db"}}')
  end

  describe '.get' do
    it 'gets a secret value' do
      result = described_class.get('database_url')

      expect(result).to eq('postgres://localhost/db')
      expect(WebMock).to have_requested(:get, 'https://vault.brainzlab.ai/api/v1/secrets/database_url')
        .with(headers: { 'X-Vault-Environment' => 'test' })
    end

    it 'returns default when secret not found' do
      stub_request(:get, %r{vault\.brainzlab\.ai/api/v1/secrets/unknown})
        .to_return(status: 404, body: '{"error": "Not found"}')

      result = described_class.get('unknown', default: 'fallback')

      expect(result).to eq('fallback')
    end

    it 'returns nil when vault is disabled' do
      BrainzLab.configuration.vault_enabled = false

      result = described_class.get('database_url')

      expect(result).to be_nil
    end

    it 'uses specified environment' do
      described_class.get('database_url', environment: 'production')

      expect(WebMock).to have_requested(:get, 'https://vault.brainzlab.ai/api/v1/secrets/database_url')
        .with(headers: { 'X-Vault-Environment' => 'production' })
    end
  end

  describe '.set' do
    it 'sets a secret value' do
      result = described_class.set('api_key', 'sk_live_123')

      expect(result).to be true
      expect(WebMock).to(have_requested(:post, 'https://vault.brainzlab.ai/api/v1/secrets')
        .with do |req|
          body = JSON.parse(req.body)
          body['key'] == 'api_key' && body['value'] == 'sk_live_123'
        end)
    end

    it 'includes description and note' do
      described_class.set('api_key', 'sk_live_123', description: 'Stripe key', note: 'Updated for v2')

      expect(WebMock).to(have_requested(:post, 'https://vault.brainzlab.ai/api/v1/secrets')
        .with do |req|
          body = JSON.parse(req.body)
          body['description'] == 'Stripe key' && body['note'] == 'Updated for v2'
        end)
    end
  end

  describe '.delete' do
    it 'deletes a secret' do
      result = described_class.delete('api_key')

      expect(result).to be true
      expect(WebMock).to have_requested(:delete, 'https://vault.brainzlab.ai/api/v1/secrets/api_key')
    end
  end

  describe '.list' do
    it 'lists all secrets' do
      result = described_class.list

      expect(result).to be_an(Array)
      expect(result.map { |s| s[:key] }).to include('database_url', 'api_key')
    end
  end

  describe '.export' do
    it 'exports secrets for environment' do
      result = described_class.export(format: :json)

      expect(result).to be_a(Hash)
      expect(result[:database_url]).to eq('postgres://localhost/db')
    end
  end

  describe 'caching' do
    before do
      BrainzLab.configuration.vault_cache_enabled = true
      BrainzLab.configuration.vault_cache_ttl = 300
      described_class.reset!
    end

    it 'caches secret values' do
      described_class.get('database_url')
      described_class.get('database_url')

      expect(WebMock).to have_requested(:get, 'https://vault.brainzlab.ai/api/v1/secrets/database_url').once
    end

    it 'invalidates cache on set' do
      described_class.get('api_key')
      described_class.set('api_key', 'new_value')
      described_class.get('api_key')

      expect(WebMock).to have_requested(:get, 'https://vault.brainzlab.ai/api/v1/secrets/api_key').twice
    end

    it 'clears cache manually' do
      described_class.get('database_url')
      described_class.clear_cache!
      described_class.get('database_url')

      expect(WebMock).to have_requested(:get, 'https://vault.brainzlab.ai/api/v1/secrets/database_url').twice
    end
  end

  describe '.reset!' do
    it 'resets all vault state' do
      described_class.get('test')

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
      expect(described_class.instance_variable_get(:@cache)).to be_nil
    end
  end
end
