# frozen_string_literal: true

require_relative 'beacon/client'
require_relative 'beacon/provisioner'

module BrainzLab
  module Beacon
    class << self
      # Create an HTTP monitor
      # @param name [String] Monitor name
      # @param url [String] URL to monitor
      # @param interval [Integer] Check interval in seconds (default: 60)
      # @param options [Hash] Additional options
      # @return [Hash, nil] Created monitor or nil
      #
      # @example
      #   BrainzLab::Beacon.create_http_monitor(
      #     "Production API",
      #     "https://api.example.com/health",
      #     interval: 30,
      #     expected_status: 200,
      #     timeout: 5
      #   )
      #
      def create_http_monitor(name, url, interval: 60, **)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.beacon_valid?

        client.create_monitor(
          name: name,
          url: url,
          type: 'http',
          interval: interval,
          **
        )
      end

      # Create an SSL certificate monitor
      def create_ssl_monitor(name, domain, warn_days: 30, **)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.beacon_valid?

        client.create_monitor(
          name: name,
          url: "https://#{domain}",
          type: 'ssl',
          ssl_warn_days: warn_days,
          **
        )
      end

      # Create a TCP port monitor
      def create_tcp_monitor(name, host, port, **)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.beacon_valid?

        client.create_monitor(
          name: name,
          url: "#{host}:#{port}",
          type: 'tcp',
          **
        )
      end

      # Create a DNS monitor
      def create_dns_monitor(name, domain, expected_record: nil, **)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.beacon_valid?

        client.create_monitor(
          name: name,
          url: domain,
          type: 'dns',
          expected_record: expected_record,
          **
        )
      end

      # Get monitor by ID
      def get(id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.beacon_valid?

        client.get_monitor(id)
      end

      # List all monitors
      def list
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.beacon_valid?

        client.list_monitors
      end

      # Update a monitor
      def update(id, **attributes)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.beacon_valid?

        client.update_monitor(id, **attributes)
      end

      # Delete a monitor
      def delete(id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.beacon_valid?

        client.delete_monitor(id)
      end

      # Pause a monitor
      def pause(id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.beacon_valid?

        client.pause_monitor(id)
      end

      # Resume a paused monitor
      def resume(id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.beacon_valid?

        client.resume_monitor(id)
      end

      # Get check history for a monitor
      def history(monitor_id, limit: 100)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.beacon_valid?

        client.check_history(monitor_id, limit: limit)
      end

      # Get overall status summary
      def status
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.beacon_valid?

        client.status_summary
      end

      # Check if all monitors are up
      def all_up?
        summary = status
        return false unless summary

        %w[up operational].include?(summary[:status])
      end

      # List active incidents
      def incidents(status: nil)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.beacon_valid?

        client.list_incidents(status: status)
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
        BrainzLab.configuration.beacon_enabled
      end
    end
  end
end
