# frozen_string_literal: true

module BrainzLab
  module Synapse
    class Provisioner
      def initialize(config)
        @config = config
        @provisioned = false
      end

      def ensure_project!
        return if @provisioned
        return unless @config.synapse_auto_provision
        return unless valid_auth?

        @provisioned = true

        project_id = detect_project_id
        return unless project_id

        client = Client.new(@config)
        client.provision(
          project_id: project_id,
          app_name: @config.app_name || @config.service
        )

        BrainzLab.debug_log("[Synapse::Provisioner] Project provisioned: #{project_id}")
      rescue StandardError => e
        BrainzLab.debug_log("[Synapse::Provisioner] Provisioning failed: #{e.message}")
      end

      private

      def valid_auth?
        key = @config.synapse_api_key || @config.synapse_master_key || @config.secret_key
        !key.nil? && !key.empty?
      end

      def detect_project_id
        ENV["BRAINZLAB_PROJECT_ID"]
      end
    end
  end
end
