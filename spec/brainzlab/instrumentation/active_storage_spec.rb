# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/active_storage'

# Mock ActiveSupport::Notifications for testing
module ActiveSupport
  module Notifications
    class Event
      attr_reader :name, :time, :end, :payload, :duration

      def initialize(name, start_time, end_time, _id, payload)
        @name = name
        @time = start_time
        @end = end_time
        @payload = payload
        @duration = (end_time - start_time) * 1000
      end
    end

    class << self
      def subscribers
        @subscribers ||= {}
      end

      def subscribe(event_name, &block)
        subscribers[event_name] ||= []
        subscribers[event_name] << block
      end

      def instrument(name, payload = {})
        start_time = Time.now
        result = yield if block_given?
        end_time = Time.now

        subscribers[name]&.each do |callback|
          callback.call(name, start_time, end_time, SecureRandom.hex(8), payload)
        end

        result
      end

      def publish(name, start_time, end_time, id, payload)
        subscribers[name]&.each do |callback|
          callback.call(name, start_time, end_time, id, payload)
        end
      end

      def clear!
        @subscribers = {}
      end
    end
  end
end

# Mock ActiveStorage for testing
module ActiveStorage; end

RSpec.describe BrainzLab::Instrumentation::ActiveStorage do
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
    it 'subscribes to ActiveStorage events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['preview.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['transform.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['analyze.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_upload.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_download.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_streaming_download.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_delete.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_delete_prefixed.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_exist.active_storage']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['service_url.active_storage']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['preview.active_storage'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['preview.active_storage'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'preview.active_storage instrumentation' do
    before { described_class.install! }

    def emit_preview(key:, duration_seconds: 0.3)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key }

      ActiveSupport::Notifications.publish(
        'preview.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for file preview' do
      emit_preview(key: 'abcd1234')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.preview' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('preview')
      expect(storage_crumb[:message]).to include('abcd1234')
      expect(storage_crumb[:level]).to eq('info')
    end

    it 'sets warning level for slow previews' do
      emit_preview(key: 'abcd1234', duration_seconds: 0.6)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.preview' }

      expect(storage_crumb[:level]).to eq('warning')
    end

    it 'adds Pulse span when trace is active' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_preview(key: 'abcd1234')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      storage_span = spans.find { |s| s[:name] == 'storage.preview' }
      expect(storage_span).not_to be_nil
      expect(storage_span[:kind]).to eq('storage')
      expect(storage_span[:data]['storage.operation']).to eq('preview')

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'transform.active_storage instrumentation' do
    before { described_class.install! }

    def emit_transform(key:, duration_seconds: 0.2)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key }

      ActiveSupport::Notifications.publish(
        'transform.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for image transform' do
      emit_transform(key: 'image-key-123')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.transform' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('transform')
      expect(storage_crumb[:message]).to include('image-key-123')
    end
  end

  describe 'analyze.active_storage instrumentation' do
    before { described_class.install! }

    def emit_analyze(analyzer:, duration_seconds: 0.1)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { analyzer: analyzer }

      ActiveSupport::Notifications.publish(
        'analyze.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for file analysis' do
      emit_analyze(analyzer: 'ImageAnalyzer')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.analyze' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('analyze')
      expect(storage_crumb[:message]).to include('ImageAnalyzer')
    end
  end

  describe 'service_upload.active_storage instrumentation' do
    before { described_class.install! }

    def emit_upload(key:, service: 'S3', duration_seconds: 0.5)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key, service: service, checksum: 'abc123' }

      ActiveSupport::Notifications.publish(
        'service_upload.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for file upload' do
      emit_upload(key: 'upload-key')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.upload' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('upload')
      expect(storage_crumb[:data][:service]).to eq('S3')
    end

    it 'adds Pulse span for upload' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_upload(key: 'upload-key', service: 'GCS')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      storage_span = spans.find { |s| s[:name] == 'storage.service.upload' }
      expect(storage_span).not_to be_nil
      expect(storage_span[:data]['storage.service']).to eq('GCS')

      BrainzLab::Pulse.finish_trace
    end

    it 'sets error level for very slow uploads' do
      emit_upload(key: 'upload-key', duration_seconds: 2.5)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.upload' }

      expect(storage_crumb[:level]).to eq('error')
    end
  end

  describe 'service_download.active_storage instrumentation' do
    before { described_class.install! }

    def emit_download(key:, service: 'S3', duration_seconds: 0.3)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key, service: service }

      ActiveSupport::Notifications.publish(
        'service_download.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for file download' do
      emit_download(key: 'download-key')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.download' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('download')
    end
  end

  describe 'service_streaming_download.active_storage instrumentation' do
    before { described_class.install! }

    def emit_streaming_download(key:, service: 'S3', duration_seconds: 0.5)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key, service: service }

      ActiveSupport::Notifications.publish(
        'service_streaming_download.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for streaming download' do
      emit_streaming_download(key: 'stream-key')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.streaming_download' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('streaming_download')
    end
  end

  describe 'service_delete.active_storage instrumentation' do
    before { described_class.install! }

    def emit_delete(key:, service: 'S3')
      start_time = Time.now
      end_time = start_time + 0.1
      payload = { key: key, service: service }

      ActiveSupport::Notifications.publish(
        'service_delete.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for file delete' do
      emit_delete(key: 'delete-key')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.delete' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:message]).to include('delete')
    end
  end

  describe 'service_delete_prefixed.active_storage instrumentation' do
    before { described_class.install! }

    def emit_delete_prefixed(prefix:, service: 'S3')
      start_time = Time.now
      end_time = start_time + 0.2
      payload = { prefix: prefix, service: service }

      ActiveSupport::Notifications.publish(
        'service_delete_prefixed.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds warning breadcrumb for bulk delete' do
      emit_delete_prefixed(prefix: 'uploads/temp/')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      storage_crumb = crumbs.find { |c| c[:category] == 'storage.delete_prefixed' }

      expect(storage_crumb).not_to be_nil
      expect(storage_crumb[:level]).to eq('warning')
      expect(storage_crumb[:message]).to include('delete prefixed')
      expect(storage_crumb[:data][:prefix]).to include('uploads/temp/')
    end
  end

  describe 'service_exist.active_storage instrumentation' do
    before { described_class.install! }

    def emit_exist(key:, exist:, service: 'S3', duration_seconds: 0.002)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key, service: service, exist: exist }

      ActiveSupport::Notifications.publish(
        'service_exist.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'skips fast existence checks' do
      emit_exist(key: 'check-key', exist: true, duration_seconds: 0.002)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans || []
      storage_span = spans.find { |s| s[:name] == 'storage.service.exist' }

      expect(storage_span).to be_nil
    end

    it 'tracks slow existence checks' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_exist(key: 'check-key', exist: false, duration_seconds: 0.010)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      storage_span = spans.find { |s| s[:name] == 'storage.service.exist' }
      expect(storage_span).not_to be_nil
      expect(storage_span[:data]['storage.exist']).to be false

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'service_url.active_storage instrumentation' do
    before { described_class.install! }

    def emit_url(key:, service: 'S3', duration_seconds: 0.005)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { key: key, service: service }

      ActiveSupport::Notifications.publish(
        'service_url.active_storage',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'skips fast URL generations' do
      emit_url(key: 'url-key', duration_seconds: 0.005)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans || []
      storage_span = spans.find { |s| s[:name] == 'storage.service.url' }

      expect(storage_span).to be_nil
    end

    it 'tracks slow URL generations' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_url(key: 'url-key', duration_seconds: 0.015)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      storage_span = spans.find { |s| s[:name] == 'storage.service.url' }
      expect(storage_span).not_to be_nil

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'helper methods' do
    describe '.truncate_key' do
      it 'truncates long keys' do
        long_key = 'uploads/' + ('a' * 150)
        result = described_class.send(:truncate_key, long_key, 50)
        expect(result.length).to eq(50)
        expect(result).to end_with('...')
      end

      it 'leaves short keys unchanged' do
        result = described_class.send(:truncate_key, 'uploads/file.jpg')
        expect(result).to eq('uploads/file.jpg')
      end

      it 'handles nil' do
        result = described_class.send(:truncate_key, nil)
        expect(result).to eq('unknown')
      end
    end
  end
end
