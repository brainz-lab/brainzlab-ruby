# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"

module BrainzLab
  module Beacon
    class Client
      def initialize(config)
        @config = config
        @base_url = config.beacon_url || "https://beacon.brainzlab.ai"
      end

      # Create a new monitor
      def create_monitor(name:, url:, type: "http", interval: 60, **options)
        response = request(
          :post,
          "/api/v1/monitors",
          body: {
            name: name,
            url: url,
            monitor_type: type,
            interval: interval,
            **options
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("create_monitor", e)
        nil
      end

      # Get monitor status
      def get_monitor(id)
        response = request(:get, "/api/v1/monitors/#{id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_monitor", e)
        nil
      end

      # List all monitors
      def list_monitors
        response = request(:get, "/api/v1/monitors")

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:monitors] || []
      rescue StandardError => e
        log_error("list_monitors", e)
        []
      end

      # Update a monitor
      def update_monitor(id, **attributes)
        response = request(
          :put,
          "/api/v1/monitors/#{id}",
          body: attributes
        )

        response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        log_error("update_monitor", e)
        false
      end

      # Delete a monitor
      def delete_monitor(id)
        response = request(:delete, "/api/v1/monitors/#{id}")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNoContent)
      rescue StandardError => e
        log_error("delete_monitor", e)
        false
      end

      # Pause a monitor
      def pause_monitor(id)
        response = request(:post, "/api/v1/monitors/#{id}/pause")
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        log_error("pause_monitor", e)
        false
      end

      # Resume a monitor
      def resume_monitor(id)
        response = request(:post, "/api/v1/monitors/#{id}/resume")
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        log_error("resume_monitor", e)
        false
      end

      # Get check history
      def check_history(monitor_id, limit: 100)
        response = request(
          :get,
          "/api/v1/monitors/#{monitor_id}/checks",
          params: { limit: limit }
        )

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:checks] || []
      rescue StandardError => e
        log_error("check_history", e)
        []
      end

      # Get current status summary
      def status_summary
        response = request(:get, "/api/v1/status")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("status_summary", e)
        nil
      end

      # List active incidents
      def list_incidents(status: nil)
        params = {}
        params[:status] = status if status

        response = request(:get, "/api/v1/incidents", params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:incidents] || []
      rescue StandardError => e
        log_error("list_incidents", e)
        []
      end

      def provision(project_id:, app_name:)
        response = request(
          :post,
          "/api/v1/projects/provision",
          body: { project_id: project_id, app_name: app_name },
          use_service_key: true
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error("provision", e)
        false
      end

      private

      def request(method, path, headers: {}, body: nil, params: nil, use_service_key: false)
        uri = URI.parse("#{@base_url}#{path}")

        if params
          uri.query = URI.encode_www_form(params)
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
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

        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"

        if use_service_key
          request["X-Service-Key"] = @config.beacon_master_key || @config.secret_key
        else
          auth_key = @config.beacon_api_key || @config.secret_key
          request["Authorization"] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Beacon::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
