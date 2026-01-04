# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/active_support_cache'

# Mock ActiveSupport::Cache for testing
module ActiveSupport
  module Cache; end
end

RSpec.describe BrainzLab::Instrumentation::ActiveSupportCache do
  before do
    ActiveSupport::Notifications.clear!

    BrainzLab.configure do |c|
      c.secret_key = 'test_key'
      c.recall_enabled = true
      c.reflex_enabled = true
      c.pulse_enabled = true
    end

    # Stub all API calls
    stub_request(:post, %r{recall\.brainzlab\.ai})
      .to_return(status: 200, body: '{}')
    stub_request(:post, %r{reflex\.brainzlab\.ai})
      .to_return(status: 200, body: '{}')
    stub_request(:post, %r{pulse\.brainzlab\.ai})
      .to_return(status: 200, body: '{}')

    # Reset the installed flag for testing
    described_class.instance_variable_set(:@installed, false)
  end

  describe '.install!' do
    it 'subscribes to cache events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['cache_read.active_support']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['cache_write.active_support']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['cache_delete.active_support']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['cache_fetch_hit.active_support']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['cache_generate.active_support']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['cache_read.active_support'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['cache_read.active_support'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'cache_read.active_support instrumentation' do
    before { described_class.install! }

    def emit_cache_read(key:, hit:, duration_seconds: 0.002, super_operation: nil)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        key: key,
        hit: hit,
        super_operation: super_operation
      }

      ActiveSupport::Notifications.publish(
        'cache_read.active_support',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for cache hit' do
      emit_cache_read(key: 'users/1', hit: true)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.read' }

      expect(cache_crumb).not_to be_nil
      expect(cache_crumb[:message]).to include('hit')
      expect(cache_crumb[:message]).to include('users/1')
      expect(cache_crumb[:data][:hit]).to be true
    end

    it 'adds breadcrumb for cache miss' do
      emit_cache_read(key: 'users/2', hit: false)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.read' }

      expect(cache_crumb[:message]).to include('miss')
      expect(cache_crumb[:data][:hit]).to be false
    end

    it 'skips read events that are part of fetch' do
      emit_cache_read(key: 'users/1', hit: true, super_operation: :fetch)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.read' }

      expect(cache_crumb).to be_nil
    end

    it 'sets warning level for slow cache reads' do
      emit_cache_read(key: 'users/1', hit: true, duration_seconds: 0.015)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.read' }

      expect(cache_crumb[:level]).to eq('warning')
    end

    it 'adds Pulse span when trace is active' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_cache_read(key: 'users/1', hit: true)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cache_span = spans.find { |s| s[:name] == 'cache.read' }
      expect(cache_span).not_to be_nil
      expect(cache_span[:kind]).to eq('cache')
      expect(cache_span[:data]['cache.hit']).to be true

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'cache_read_multi.active_support instrumentation' do
    before { described_class.install! }

    def emit_cache_read_multi(keys:, hits:, duration_seconds: 0.005)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        key: keys,
        hits: hits
      }

      ActiveSupport::Notifications.publish(
        'cache_read_multi.active_support',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb with hit rate' do
      emit_cache_read_multi(keys: %w[a b c d], hits: %w[a b])

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.read_multi' }

      expect(cache_crumb).not_to be_nil
      expect(cache_crumb[:message]).to include('2/4 hits')
      expect(cache_crumb[:data][:key_count]).to eq(4)
      expect(cache_crumb[:data][:hit_count]).to eq(2)
      expect(cache_crumb[:data][:hit_rate]).to eq(50.0)
    end
  end

  describe 'cache_write.active_support instrumentation' do
    before { described_class.install! }

    def emit_cache_write(key:, duration_seconds: 0.002)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key }

      ActiveSupport::Notifications.publish(
        'cache_write.active_support',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for cache write' do
      emit_cache_write(key: 'users/1')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.write' }

      expect(cache_crumb).not_to be_nil
      expect(cache_crumb[:message]).to include('write')
      expect(cache_crumb[:message]).to include('users/1')
    end

    it 'adds Pulse span for cache write' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_cache_write(key: 'users/1')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cache_span = spans.find { |s| s[:name] == 'cache.write' }
      expect(cache_span).not_to be_nil
      expect(cache_span[:data]['cache.operation']).to eq('write')

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'cache_delete.active_support instrumentation' do
    before { described_class.install! }

    def emit_cache_delete(key:)
      start_time = Time.now
      end_time = start_time + 0.001
      payload = { key: key }

      ActiveSupport::Notifications.publish(
        'cache_delete.active_support',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for cache delete' do
      emit_cache_delete(key: 'users/1')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.delete' }

      expect(cache_crumb).not_to be_nil
      expect(cache_crumb[:message]).to include('delete')
    end
  end

  describe 'cache_fetch_hit.active_support instrumentation' do
    before { described_class.install! }

    def emit_cache_fetch_hit(key:, duration_seconds: 0.002)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key }

      ActiveSupport::Notifications.publish(
        'cache_fetch_hit.active_support',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for fetch hit' do
      emit_cache_fetch_hit(key: 'users/1')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.fetch' }

      expect(cache_crumb).not_to be_nil
      expect(cache_crumb[:message]).to include('hit')
      expect(cache_crumb[:data][:hit]).to be true
    end
  end

  describe 'cache_generate.active_support instrumentation' do
    before { described_class.install! }

    def emit_cache_generate(key:, duration_seconds: 0.02)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key }

      ActiveSupport::Notifications.publish(
        'cache_generate.active_support',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for cache miss + generate' do
      emit_cache_generate(key: 'users/1')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.generate' }

      expect(cache_crumb).not_to be_nil
      expect(cache_crumb[:message]).to include('miss')
      expect(cache_crumb[:message]).to include('generate')
      expect(cache_crumb[:data][:hit]).to be false
    end

    it 'sets warning level for slow generations' do
      emit_cache_generate(key: 'users/1', duration_seconds: 0.015)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.generate' }

      expect(cache_crumb[:level]).to eq('warning')
    end

    it 'sets error level for very slow generations' do
      emit_cache_generate(key: 'users/1', duration_seconds: 0.06)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cache_crumb = crumbs.find { |c| c[:category] == 'cache.generate' }

      expect(cache_crumb[:level]).to eq('error')
    end
  end

  describe 'helper methods' do
    describe '.truncate_key' do
      it 'truncates long keys' do
        long_key = 'cache/' + ('a' * 150)
        result = described_class.send(:truncate_key, long_key, 50)
        expect(result.length).to eq(50)
        expect(result).to end_with('...')
      end

      it 'leaves short keys unchanged' do
        result = described_class.send(:truncate_key, 'users/1')
        expect(result).to eq('users/1')
      end

      it 'handles nil' do
        result = described_class.send(:truncate_key, nil)
        expect(result).to eq('unknown')
      end
    end
  end
end
