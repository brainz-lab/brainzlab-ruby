# frozen_string_literal: true

require_relative "synapse/client"
require_relative "synapse/provisioner"

module BrainzLab
  module Synapse
    class << self
      # List all projects
      # @param status [String] Filter by status (running, stopped, deploying)
      # @return [Array<Hash>] List of projects
      #
      # @example
      #   projects = BrainzLab::Synapse.projects(status: "running")
      #
      def projects(status: nil, page: 1, per_page: 20)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.synapse_valid?

        client.list_projects(status: status, page: page, per_page: per_page)
      end

      # Get project details
      # @param project_id [String] Project ID
      # @return [Hash, nil] Project details
      def project(project_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.get_project(project_id)
      end

      # Create a new project
      # @param name [String] Project name
      # @param repos [Array<Hash>] Repository configurations
      # @param description [String] Project description
      # @return [Hash, nil] Created project
      #
      # @example
      #   project = BrainzLab::Synapse.create_project(
      #     name: "My App",
      #     repos: [
      #       { url: "https://github.com/org/api", type: "rails" },
      #       { url: "https://github.com/org/frontend", type: "react" }
      #     ]
      #   )
      #
      def create_project(name:, repos: [], description: nil, **options)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.create_project(name: name, repos: repos, description: description, **options)
      end

      # Start project containers
      # @param project_id [String] Project ID
      # @return [Boolean] True if started
      def up(project_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.synapse_valid?

        client.start_project(project_id)
      end

      # Stop project containers
      # @param project_id [String] Project ID
      # @return [Boolean] True if stopped
      def down(project_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.synapse_valid?

        client.stop_project(project_id)
      end

      # Restart project containers
      # @param project_id [String] Project ID
      # @return [Boolean] True if restarted
      def restart(project_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.synapse_valid?

        client.restart_project(project_id)
      end

      # Deploy project to environment
      # @param project_id [String] Project ID
      # @param environment [Symbol] Target environment (:staging, :production)
      # @param options [Hash] Deployment options
      # @return [Hash, nil] Deployment info
      #
      # @example
      #   deployment = BrainzLab::Synapse.deploy(project_id, environment: :staging)
      #
      def deploy(project_id, environment:, **options)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.deploy(project_id, environment: environment, options: options)
      end

      # Get deployment status
      # @param deployment_id [String] Deployment ID
      # @return [Hash, nil] Deployment details
      def deployment(deployment_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.get_deployment(deployment_id)
      end

      # Create an AI development task
      # @param project_id [String] Project ID
      # @param description [String] Task description in natural language
      # @param type [Symbol] Task type (:feature, :bugfix, :refactor, :test)
      # @param priority [Symbol] Priority (:low, :medium, :high, :urgent)
      # @return [Hash, nil] Created task
      #
      # @example
      #   task = BrainzLab::Synapse.task(
      #     project_id: project_id,
      #     description: "Add user authentication with OAuth",
      #     type: :feature,
      #     priority: :high
      #   )
      #
      def task(project_id:, description:, type: nil, priority: nil, **options)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.create_task(
          project_id: project_id,
          description: description,
          type: type,
          priority: priority,
          **options
        )
      end

      # Get task details
      # @param task_id [String] Task ID
      # @return [Hash, nil] Task details
      def get_task(task_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.get_task(task_id)
      end

      # Get task status and progress
      # @param task_id [String] Task ID
      # @return [Hash, nil] Task status with progress
      def task_status(task_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.get_task_status(task_id)
      end

      # List tasks
      # @param project_id [String] Optional filter by project
      # @param status [String] Filter by status (pending, running, completed, failed)
      # @return [Array<Hash>] List of tasks
      def tasks(project_id: nil, status: nil, page: 1, per_page: 20)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.synapse_valid?

        client.list_tasks(project_id: project_id, status: status, page: page, per_page: per_page)
      end

      # Cancel a running task
      # @param task_id [String] Task ID
      # @return [Boolean] True if cancelled
      def cancel_task(task_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.synapse_valid?

        client.cancel_task(task_id)
      end

      # Get container logs
      # @param project_id [String] Project ID
      # @param container [String] Optional container name
      # @param lines [Integer] Number of lines (default: 100)
      # @param since [String] Start time (ISO8601)
      # @return [Hash, nil] Log data
      def logs(project_id, container: nil, lines: 100, since: nil)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.get_logs(project_id, container: container, lines: lines, since: since)
      end

      # Execute command in container
      # @param project_id [String] Project ID
      # @param command [String] Command to execute
      # @param container [String] Optional container name
      # @param timeout [Integer] Timeout in seconds
      # @return [Hash, nil] Command output
      #
      # @example
      #   result = BrainzLab::Synapse.exec(project_id, command: "rails db:migrate")
      #
      def exec(project_id, command:, container: nil, timeout: 30)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.synapse_valid?

        client.exec(project_id, command: command, container: container, timeout: timeout)
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
        BrainzLab.configuration.synapse_enabled
      end
    end
  end
end
