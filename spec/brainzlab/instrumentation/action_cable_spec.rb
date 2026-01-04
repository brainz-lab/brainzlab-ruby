# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/action_cable'

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

# Mock ActionCable for testing
module ActionCable; end

RSpec.describe BrainzLab::Instrumentation::ActionCable do
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
    it 'subscribes to ActionCable events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['perform_action.action_cable']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['transmit.action_cable']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['transmit_subscription_confirmation.action_cable']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['transmit_subscription_rejection.action_cable']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['broadcast.action_cable']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['perform_action.action_cable'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['perform_action.action_cable'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'perform_action.action_cable instrumentation' do
    before { described_class.install! }

    def emit_perform_action(channel_class:, action:, duration_seconds: 0.05)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        channel_class: channel_class,
        action: action,
        data: { message: 'hello' }
      }

      ActiveSupport::Notifications.publish(
        'perform_action.action_cable',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for action' do
      emit_perform_action(channel_class: 'ChatChannel', action: 'speak')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.action' }

      expect(cable_crumb).not_to be_nil
      expect(cable_crumb[:message]).to include('ChatChannel')
      expect(cable_crumb[:message]).to include('speak')
      expect(cable_crumb[:level]).to eq('info')
      expect(cable_crumb[:data][:channel]).to eq('ChatChannel')
      expect(cable_crumb[:data][:action]).to eq('speak')
    end

    it 'sets warning level for slow actions' do
      emit_perform_action(channel_class: 'ChatChannel', action: 'speak', duration_seconds: 0.15)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.action' }

      expect(cable_crumb[:level]).to eq('warning')
    end

    it 'sets error level for very slow actions' do
      emit_perform_action(channel_class: 'ChatChannel', action: 'speak', duration_seconds: 0.6)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.action' }

      expect(cable_crumb[:level]).to eq('error')
    end

    it 'adds Pulse span when trace is active' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_perform_action(channel_class: 'ChatChannel', action: 'speak')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cable_span = spans.find { |s| s[:name].start_with?('cable.action') }
      expect(cable_span).not_to be_nil
      expect(cable_span[:kind]).to eq('websocket')
      expect(cable_span[:data]['cable.channel']).to eq('ChatChannel')
      expect(cable_span[:data]['cable.action']).to eq('speak')

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'transmit.action_cable instrumentation' do
    before { described_class.install! }

    def emit_transmit(channel_class:, via: nil, duration_seconds: 0.01)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        channel_class: channel_class,
        data: { content: 'message' },
        via: via
      }

      ActiveSupport::Notifications.publish(
        'transmit.action_cable',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for transmit' do
      emit_transmit(channel_class: 'ChatChannel')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.transmit' }

      expect(cable_crumb).not_to be_nil
      expect(cable_crumb[:message]).to include('transmit')
      expect(cable_crumb[:message]).to include('ChatChannel')
    end

    it 'includes via information when present' do
      emit_transmit(channel_class: 'ChatChannel', via: 'streaming')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.transmit' }

      expect(cable_crumb[:message]).to include('via streaming')
      expect(cable_crumb[:data][:via]).to eq('streaming')
    end

    it 'adds Pulse span for transmit' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_transmit(channel_class: 'ChatChannel', via: 'streaming')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cable_span = spans.find { |s| s[:name] == 'cable.transmit' }
      expect(cable_span).not_to be_nil
      expect(cable_span[:data]['cable.via']).to eq('streaming')

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'transmit_subscription_confirmation.action_cable instrumentation' do
    before { described_class.install! }

    def emit_subscription_confirmation(channel_class:)
      start_time = Time.now
      end_time = start_time + 0.01
      payload = { channel_class: channel_class }

      ActiveSupport::Notifications.publish(
        'transmit_subscription_confirmation.action_cable',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for subscription confirmation' do
      emit_subscription_confirmation(channel_class: 'NotificationChannel')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.subscribe' && c[:data][:status] == 'confirmed' }

      expect(cable_crumb).not_to be_nil
      expect(cable_crumb[:message]).to include('subscribed')
      expect(cable_crumb[:message]).to include('NotificationChannel')
      expect(cable_crumb[:level]).to eq('info')
    end

    it 'adds Pulse span for subscription' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_subscription_confirmation(channel_class: 'NotificationChannel')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cable_span = spans.find { |s| s[:name] == 'cable.subscribe' }
      expect(cable_span).not_to be_nil
      expect(cable_span[:data]['cable.subscription_status']).to eq('confirmed')
      expect(cable_span[:error]).to be false

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'transmit_subscription_rejection.action_cable instrumentation' do
    before { described_class.install! }

    def emit_subscription_rejection(channel_class:)
      start_time = Time.now
      end_time = start_time + 0.01
      payload = { channel_class: channel_class }

      ActiveSupport::Notifications.publish(
        'transmit_subscription_rejection.action_cable',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds warning breadcrumb for subscription rejection' do
      emit_subscription_rejection(channel_class: 'AdminChannel')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.subscribe' && c[:data][:status] == 'rejected' }

      expect(cable_crumb).not_to be_nil
      expect(cable_crumb[:message]).to include('rejected')
      expect(cable_crumb[:message]).to include('AdminChannel')
      expect(cable_crumb[:level]).to eq('warning')
    end

    it 'adds Pulse span with error flag for rejection' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_subscription_rejection(channel_class: 'AdminChannel')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cable_span = spans.find { |s| s[:name] == 'cable.subscribe' && s[:data]['cable.subscription_status'] == 'rejected' }
      expect(cable_span).not_to be_nil
      expect(cable_span[:error]).to be true

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'broadcast.action_cable instrumentation' do
    before { described_class.install! }

    def emit_broadcast(broadcasting:, coder: nil, duration_seconds: 0.02)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        broadcasting: broadcasting,
        message: { content: 'broadcast message' },
        coder: coder
      }

      ActiveSupport::Notifications.publish(
        'broadcast.action_cable',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for broadcast' do
      emit_broadcast(broadcasting: 'chat_room_1')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.broadcast' }

      expect(cable_crumb).not_to be_nil
      expect(cable_crumb[:message]).to include('broadcast')
      expect(cable_crumb[:message]).to include('chat_room_1')
      expect(cable_crumb[:data][:broadcasting]).to eq('chat_room_1')
    end

    it 'includes coder information when present' do
      coder_mock = double('Coder')
      allow(coder_mock).to receive(:to_s).and_return('ActiveSupport::JSON')

      emit_broadcast(broadcasting: 'chat_room_1', coder: coder_mock)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      cable_crumb = crumbs.find { |c| c[:category] == 'cable.broadcast' }

      expect(cable_crumb[:data][:coder]).to eq('ActiveSupport::JSON')
    end

    it 'adds Pulse span for broadcast' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_broadcast(broadcasting: 'notifications')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      cable_span = spans.find { |s| s[:name] == 'cable.broadcast' }
      expect(cable_span).not_to be_nil
      expect(cable_span[:kind]).to eq('websocket')
      expect(cable_span[:data]['cable.broadcasting']).to eq('notifications')

      BrainzLab::Pulse.finish_trace
    end
  end
end
