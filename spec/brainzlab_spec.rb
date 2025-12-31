# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab do
  describe '.configure' do
    it 'yields configuration' do
      described_class.configure do |config|
        config.secret_key = 'test_key'
        config.service = 'test-service'
      end

      expect(described_class.configuration.secret_key).to eq('test_key')
      expect(described_class.configuration.service).to eq('test-service')
    end
  end

  describe '.set_user' do
    it 'sets user context' do
      described_class.set_user(id: 123, email: 'test@example.com')

      context = BrainzLab::Context.current
      expect(context.user[:id]).to eq(123)
      expect(context.user[:email]).to eq('test@example.com')
    end
  end

  describe '.set_context' do
    it 'sets extra context' do
      described_class.set_context(deployment: 'v1.0', region: 'us-east-1')

      context = BrainzLab::Context.current
      expect(context.extra[:deployment]).to eq('v1.0')
      expect(context.extra[:region]).to eq('us-east-1')
    end
  end

  describe '.with_context' do
    it 'scopes context to block' do
      described_class.set_context(base: true)

      described_class.with_context(scoped: true) do
        context = BrainzLab::Context.current
        expect(context.data_hash[:base]).to be(true)
        expect(context.data_hash[:scoped]).to be(true)
      end

      context = BrainzLab::Context.current
      expect(context.data_hash[:base]).to be(true)
      expect(context.data_hash[:scoped]).to be_nil
    end
  end
end
