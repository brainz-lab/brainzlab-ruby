# frozen_string_literal: true

require_relative "sentinel/client"
require_relative "sentinel/provisioner"

module BrainzLab
  module Sentinel
    class << self
      # List all registered hosts
      # @param status [String] Filter by status (online, offline, warning, critical)
      # @param page [Integer] Page number
      # @param per_page [Integer] Results per page
      # @return [Array<Hash>] List of hosts
      #
      # @example
      #   hosts = BrainzLab::Sentinel.hosts(status: "online")
      #
      def hosts(status: nil, page: 1, per_page: 50)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.sentinel_valid?

        client.list_hosts(status: status, page: page, per_page: per_page)
      end

      # Get host details
      # @param host_id [String] Host ID
      # @return [Hash, nil] Host details
      def host(host_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.sentinel_valid?

        client.get_host(host_id)
      end

      # Get metrics for a host
      # @param host_id [String] Host ID
      # @param period [String] Time period (1h, 6h, 24h, 7d, 30d)
      # @param metrics [Array<String>] Specific metrics (cpu, memory, disk, network)
      # @return [Hash, nil] Metrics data
      #
      # @example
      #   metrics = BrainzLab::Sentinel.metrics(host_id, period: "24h", metrics: ["cpu", "memory"])
      #
      def metrics(host_id, period: "1h", metrics: nil)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.sentinel_valid?

        client.get_metrics(host_id, period: period, metrics: metrics)
      end

      # Get top processes for a host
      # @param host_id [String] Host ID
      # @param sort_by [String] Sort by (cpu, memory, time)
      # @param limit [Integer] Max results
      # @return [Array<Hash>] Process list
      #
      # @example
      #   procs = BrainzLab::Sentinel.processes(host_id, sort_by: "memory", limit: 10)
      #
      def processes(host_id, sort_by: "cpu", limit: 20)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.sentinel_valid?

        client.get_processes(host_id, sort_by: sort_by, limit: limit)
      end

      # List all containers
      # @param host_id [String] Optional filter by host
      # @param status [String] Filter by status (running, stopped, paused)
      # @return [Array<Hash>] Container list
      #
      # @example
      #   containers = BrainzLab::Sentinel.containers(host_id: "host_123", status: "running")
      #
      def containers(host_id: nil, status: nil)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.sentinel_valid?

        client.list_containers(host_id: host_id, status: status)
      end

      # Get container details
      # @param container_id [String] Container ID
      # @return [Hash, nil] Container details
      def container(container_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.sentinel_valid?

        client.get_container(container_id)
      end

      # Get container metrics
      # @param container_id [String] Container ID
      # @param period [String] Time period
      # @return [Hash, nil] Container metrics
      def container_metrics(container_id, period: "1h")
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.sentinel_valid?

        client.get_container_metrics(container_id, period: period)
      end

      # Get alerts
      # @param host_id [String] Optional filter by host
      # @param status [String] Filter by status (active, acknowledged, resolved)
      # @param severity [String] Filter by severity (info, warning, critical)
      # @return [Array<Hash>] Alert list
      #
      # @example
      #   alerts = BrainzLab::Sentinel.alerts(severity: "critical", status: "active")
      #
      def alerts(host_id: nil, status: nil, severity: nil)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.sentinel_valid?

        client.get_alerts(host_id: host_id, status: status, severity: severity)
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
        BrainzLab.configuration.sentinel_enabled
      end
    end
  end
end
