# frozen_string_literal: true

require_relative "flux/client"
require_relative "flux/buffer"
require_relative "flux/provisioner"

module BrainzLab
  module Flux
    class << self
      # === EVENTS ===

      # Track a custom event
      # @param name [String] Event name (e.g., 'user.signup', 'order.completed')
      # @param properties [Hash] Event properties
      def track(name, properties = {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.flux_valid?

        event = {
          name: name,
          timestamp: Time.now.utc.iso8601(3),
          properties: properties.except(:user_id, :value, :tags, :session_id),
          user_id: properties[:user_id],
          session_id: properties[:session_id],
          value: properties[:value],
          tags: properties[:tags] || {},
          environment: BrainzLab.configuration.environment,
          service: BrainzLab.configuration.service
        }

        buffer.add(:event, event)
      end

      # Track event for a specific user
      def track_for_user(user, name, properties = {})
        user_id = user.respond_to?(:id) ? user.id.to_s : user.to_s
        track(name, properties.merge(user_id: user_id))
      end

      # === METRICS ===

      # Gauge: Current value (overwrites)
      def gauge(name, value, tags: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.flux_valid?

        metric = {
          type: "gauge",
          name: name,
          value: value,
          tags: tags,
          timestamp: Time.now.utc.iso8601(3)
        }

        buffer.add(:metric, metric)
      end

      # Counter: Increment value
      def increment(name, value = 1, tags: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.flux_valid?

        metric = {
          type: "counter",
          name: name,
          value: value,
          tags: tags,
          timestamp: Time.now.utc.iso8601(3)
        }

        buffer.add(:metric, metric)
      end

      # Counter: Decrement value
      def decrement(name, value = 1, tags: {})
        increment(name, -value, tags: tags)
      end

      # Distribution: Statistical aggregation
      def distribution(name, value, tags: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.flux_valid?

        metric = {
          type: "distribution",
          name: name,
          value: value,
          tags: tags,
          timestamp: Time.now.utc.iso8601(3)
        }

        buffer.add(:metric, metric)
      end

      # Set: Unique count (cardinality)
      def set(name, value, tags: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.flux_valid?

        metric = {
          type: "set",
          name: name,
          value: value.to_s,
          tags: tags,
          timestamp: Time.now.utc.iso8601(3)
        }

        buffer.add(:metric, metric)
      end

      # === CONVENIENCE METHODS ===

      # Time a block and record as distribution
      def measure(name, tags: {})
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          yield
        ensure
          duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
          distribution(name, duration_ms, tags: tags.merge(unit: "ms"))
        end
      end

      # Flush any buffered data immediately
      def flush!
        buffer.flush!
      end

      # === INTERNAL ===

      def ensure_provisioned!
        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def buffer
        @buffer ||= Buffer.new(client)
      end

      def reset!
        @client = nil
        @buffer = nil
        @provisioner = nil
        @provisioned = false
      end

      private

      def enabled?
        BrainzLab.configuration.flux_effectively_enabled?
      end
    end
  end
end
