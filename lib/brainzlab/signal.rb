# frozen_string_literal: true

require_relative "signal/client"
require_relative "signal/provisioner"

module BrainzLab
  module Signal
    SEVERITIES = %i[info warning error critical].freeze

    class << self
      # Send an alert with a message
      # @param name [String] Alert name (e.g., 'high_error_rate', 'low_disk_space')
      # @param message [String] Alert message
      # @param severity [Symbol] Alert severity (:info, :warning, :error, :critical)
      # @param channels [Array<String>] Channels to send alert to (e.g., ['slack', 'email'])
      # @param data [Hash] Additional data to include with the alert
      def alert(name, message, severity: :warning, channels: nil, data: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.signal_valid?

        payload = {
          type: "alert",
          name: name,
          message: message,
          severity: severity.to_s,
          channels: channels,
          data: data,
          timestamp: Time.now.utc.iso8601(3),
          environment: BrainzLab.configuration.environment,
          service: BrainzLab.configuration.service,
          host: BrainzLab.configuration.host,
          context: context_data
        }

        client.send_alert(payload)
      end

      # Send a notification to specific channels
      # @param channel [String, Array<String>] Channel(s) to send to ('slack', 'email', 'webhook')
      # @param message [String] Notification message
      # @param title [String] Optional notification title
      # @param data [Hash] Additional data
      def notify(channel, message, title: nil, data: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.signal_valid?

        channels = Array(channel)
        payload = {
          type: "notification",
          channels: channels,
          message: message,
          title: title,
          data: data,
          timestamp: Time.now.utc.iso8601(3),
          environment: BrainzLab.configuration.environment,
          service: BrainzLab.configuration.service
        }

        client.send_notification(payload)
      end

      # Trigger a predefined alert rule
      # @param rule_name [String] Name of the alert rule to trigger
      # @param context [Hash] Context data to pass to the rule
      def trigger(rule_name, context = {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.signal_valid?

        payload = {
          type: "trigger",
          rule: rule_name,
          context: context,
          timestamp: Time.now.utc.iso8601(3),
          environment: BrainzLab.configuration.environment,
          service: BrainzLab.configuration.service
        }

        client.trigger_rule(payload)
      end

      # Send a test alert to verify configuration
      def test!
        alert(
          "test_alert",
          "This is a test alert from BrainzLab Signal SDK",
          severity: :info,
          data: { test: true, sdk_version: BrainzLab::VERSION }
        )
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

      def reset!
        @client = nil
        @provisioner = nil
        @provisioned = false
      end

      private

      def enabled?
        BrainzLab.configuration.signal_effectively_enabled?
      end

      def context_data
        ctx = BrainzLab::Context.current
        {
          user: ctx.user,
          tags: ctx.tags,
          extra: ctx.context
        }
      end
    end
  end
end
