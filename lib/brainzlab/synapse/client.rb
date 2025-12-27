# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module BrainzLab
  module Synapse
    class Client
      def initialize(config)
        @config = config
        @base_url = config.synapse_url || "https://synapse.brainzlab.ai"
      end

      # List all projects
      def list_projects(status: nil, page: 1, per_page: 20)
        params = { page: page, per_page: per_page }
        params[:status] = status if status

        response = request(:get, "/api/v1/projects", params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:projects] || []
      rescue StandardError => e
        log_error("list_projects", e)
        []
      end

      # Get project details
      def get_project(project_id)
        response = request(:get, "/api/v1/projects/#{project_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_project", e)
        nil
      end

      # Create a new project
      def create_project(name:, repos: [], description: nil, **options)
        response = request(
          :post,
          "/api/v1/projects",
          body: {
            name: name,
            description: description,
            repos: repos,
            **options
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("create_project", e)
        nil
      end

      # Start project containers
      def start_project(project_id)
        response = request(:post, "/api/v1/projects/#{project_id}/up")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
      rescue StandardError => e
        log_error("start_project", e)
        false
      end

      # Stop project containers
      def stop_project(project_id)
        response = request(:post, "/api/v1/projects/#{project_id}/down")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
      rescue StandardError => e
        log_error("stop_project", e)
        false
      end

      # Restart project containers
      def restart_project(project_id)
        response = request(:post, "/api/v1/projects/#{project_id}/restart")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
      rescue StandardError => e
        log_error("restart_project", e)
        false
      end

      # Deploy project to environment
      def deploy(project_id, environment:, options: {})
        response = request(
          :post,
          "/api/v1/projects/#{project_id}/deploy",
          body: {
            environment: environment,
            **options
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("deploy", e)
        nil
      end

      # Get deployment status
      def get_deployment(deployment_id)
        response = request(:get, "/api/v1/deployments/#{deployment_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_deployment", e)
        nil
      end

      # Create an AI task
      def create_task(project_id:, description:, type: nil, priority: nil, **options)
        response = request(
          :post,
          "/api/v1/tasks",
          body: {
            project_id: project_id,
            description: description,
            type: type,
            priority: priority,
            **options
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("create_task", e)
        nil
      end

      # Get task status
      def get_task(task_id)
        response = request(:get, "/api/v1/tasks/#{task_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_task", e)
        nil
      end

      # Get task status and progress
      def get_task_status(task_id)
        response = request(:get, "/api/v1/tasks/#{task_id}/status")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_task_status", e)
        nil
      end

      # List tasks for a project
      def list_tasks(project_id: nil, status: nil, page: 1, per_page: 20)
        params = { page: page, per_page: per_page }
        params[:project_id] = project_id if project_id
        params[:status] = status if status

        response = request(:get, "/api/v1/tasks", params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:tasks] || []
      rescue StandardError => e
        log_error("list_tasks", e)
        []
      end

      # Cancel a running task
      def cancel_task(task_id)
        response = request(:post, "/api/v1/tasks/#{task_id}/cancel")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
      rescue StandardError => e
        log_error("cancel_task", e)
        false
      end

      # Get container logs
      def get_logs(project_id, container: nil, lines: 100, since: nil)
        params = { lines: lines }
        params[:container] = container if container
        params[:since] = since if since

        response = request(:get, "/api/v1/projects/#{project_id}/logs", params: params)

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_logs", e)
        nil
      end

      # Execute command in container
      def exec(project_id, command:, container: nil, timeout: 30)
        response = request(
          :post,
          "/api/v1/projects/#{project_id}/exec",
          body: {
            command: command,
            container: container,
            timeout: timeout
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("exec", e)
        nil
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
        http.read_timeout = 120  # Longer timeout for AI tasks

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
          request["X-Service-Key"] = @config.synapse_master_key || @config.secret_key
        else
          auth_key = @config.synapse_api_key || @config.secret_key
          request["Authorization"] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Synapse::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
