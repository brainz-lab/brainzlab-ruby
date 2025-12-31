# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module BrainzLab
  module Sentinel
    class Client
      def initialize(config)
        @config = config
        @base_url = config.sentinel_url || 'https://sentinel.brainzlab.ai'
      end

      # List all registered hosts
      def list_hosts(status: nil, page: 1, per_page: 50)
        params = { page: page, per_page: per_page }
        params[:status] = status if status

        response = request(:get, '/api/v1/hosts', params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:hosts] || []
      rescue StandardError => e
        log_error('list_hosts', e)
        []
      end

      # Get host details
      def get_host(host_id)
        response = request(:get, "/api/v1/hosts/#{host_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('get_host', e)
        nil
      end

      # Get host metrics
      # @param host_id [String] Host ID
      # @param period [String] Time period (1h, 6h, 24h, 7d, 30d)
      # @param metrics [Array<String>] Specific metrics to fetch (cpu, memory, disk, network)
      def get_metrics(host_id, period: '1h', metrics: nil)
        params = { period: period }
        params[:metrics] = metrics.join(',') if metrics

        response = request(:get, "/api/v1/hosts/#{host_id}/metrics", params: params)

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('get_metrics', e)
        nil
      end

      # Get top processes for a host
      def get_processes(host_id, sort_by: 'cpu', limit: 20)
        params = { sort_by: sort_by, limit: limit }

        response = request(:get, "/api/v1/hosts/#{host_id}/processes", params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:processes] || []
      rescue StandardError => e
        log_error('get_processes', e)
        []
      end

      # List all containers
      def list_containers(host_id: nil, status: nil)
        params = {}
        params[:host_id] = host_id if host_id
        params[:status] = status if status

        response = request(:get, '/api/v1/containers', params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:containers] || []
      rescue StandardError => e
        log_error('list_containers', e)
        []
      end

      # Get container details
      def get_container(container_id)
        response = request(:get, "/api/v1/containers/#{container_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('get_container', e)
        nil
      end

      # Get container metrics
      def get_container_metrics(container_id, period: '1h')
        params = { period: period }

        response = request(:get, "/api/v1/containers/#{container_id}/metrics", params: params)

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('get_container_metrics', e)
        nil
      end

      # Get alerts for a host
      def get_alerts(host_id: nil, status: nil, severity: nil)
        params = {}
        params[:host_id] = host_id if host_id
        params[:status] = status if status
        params[:severity] = severity if severity

        response = request(:get, '/api/v1/alerts', params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:alerts] || []
      rescue StandardError => e
        log_error('get_alerts', e)
        []
      end

      # Report metrics from agent (internal use)
      def report_metrics(host_id:, metrics:, timestamp: nil)
        response = request(
          :post,
          '/internal/agent/report',
          body: {
            host_id: host_id,
            metrics: metrics,
            timestamp: timestamp || Time.now.utc.iso8601
          },
          use_agent_key: true
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
      rescue StandardError => e
        log_error('report_metrics', e)
        false
      end

      def provision(project_id:, app_name:)
        response = request(
          :post,
          '/api/v1/projects/provision',
          body: { project_id: project_id, app_name: app_name },
          use_service_key: true
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error('provision', e)
        false
      end

      private

      def request(method, path, headers: {}, body: nil, params: nil, use_service_key: false, use_agent_key: false)
        uri = URI.parse("#{@base_url}#{path}")

        uri.query = URI.encode_www_form(params) if params

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 10
        http.read_timeout = 30

        request = case method
                  when :get
                    Net::HTTP::Get.new(uri)
                  when :post
                    Net::HTTP::Post.new(uri)
                  when :put
                    Net::HTTP::Put.new(uri)
                  when :delete
                    Net::HTTP::Delete.new(uri)
                  end

        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'

        if use_service_key
          request['X-Service-Key'] = @config.sentinel_master_key || @config.secret_key
        elsif use_agent_key
          request['X-Agent-Key'] = @config.sentinel_agent_key || @config.sentinel_api_key || @config.secret_key
        else
          auth_key = @config.sentinel_api_key || @config.secret_key
          request['Authorization'] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Sentinel::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
