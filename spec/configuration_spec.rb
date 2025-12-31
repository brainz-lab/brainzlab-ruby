# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Configuration do
  let(:config) { described_class.new }

  describe 'defaults' do
    it 'has default recall settings' do
      expect(config.recall_enabled).to be(true)
      expect(config.recall_url).to eq('https://recall.brainzlab.ai')
      expect(config.recall_min_level).to eq(:debug)
      expect(config.recall_buffer_size).to eq(50)
      expect(config.recall_flush_interval).to eq(5)
    end

    it 'has default reflex settings' do
      expect(config.reflex_enabled).to be(true)
      expect(config.reflex_url).to eq('https://reflex.brainzlab.ai')
      expect(config.reflex_excluded_exceptions).to eq([])
    end

    it 'has default scrub fields' do
      expect(config.scrub_fields).to include(:password, :token, :api_key)
    end
  end

  describe '#recall_min_level=' do
    it 'accepts valid levels' do
      %i[debug info warn error fatal].each do |level|
        config.recall_min_level = level
        expect(config.recall_min_level).to eq(level)
      end
    end

    it 'raises for invalid levels' do
      expect { config.recall_min_level = :invalid }.to raise_error(ArgumentError)
    end
  end

  describe '#level_enabled?' do
    it 'returns true for levels at or above min' do
      config.recall_min_level = :warn

      expect(config.level_enabled?(:debug)).to be(false)
      expect(config.level_enabled?(:info)).to be(false)
      expect(config.level_enabled?(:warn)).to be(true)
      expect(config.level_enabled?(:error)).to be(true)
      expect(config.level_enabled?(:fatal)).to be(true)
    end
  end

  describe '#valid?' do
    it 'returns false without secret_key' do
      expect(config.valid?).to be(false)
    end

    it 'returns true with secret_key' do
      config.secret_key = 'test_key'
      expect(config.valid?).to be(true)
    end
  end
end
