# frozen_string_literal: true

module BrainzLab
  module Vault
    class Provisioner
      def initialize(config)
        @config = config
        @provisioned = false
      end

      def ensure_project!
        return if @provisioned
        return unless @config.vault_auto_provision
        return unless valid_auth?

        @provisioned = true

        # Try to provision with Platform project ID
        project_id = detect_project_id
        return unless project_id

        client = Client.new(@config)
        client.provision(
          project_id: project_id,
          app_name: @config.app_name || @config.service
        )

        BrainzLab.debug_log("[Vault::Provisioner] Project provisioned: #{project_id}")
      rescue StandardError => e
        BrainzLab.debug_log("[Vault::Provisioner] Provisioning failed: #{e.message}")
      end

      private

      def valid_auth?
        key = @config.vault_api_key || @config.vault_master_key || @config.secret_key
        !key.nil? && !key.empty?
      end

      def detect_project_id
        # Try environment variable first
        return ENV["BRAINZLAB_PROJECT_ID"] if ENV["BRAINZLAB_PROJECT_ID"]

        # Could also detect from Platform API if we have a secret key
        nil
      end
    end
  end
end
