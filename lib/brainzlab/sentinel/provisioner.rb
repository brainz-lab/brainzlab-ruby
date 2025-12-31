# frozen_string_literal: true

module BrainzLab
  module Sentinel
    class Provisioner
      def initialize(config)
        @config = config
        @provisioned = false
      end

      def ensure_project!
        return if @provisioned
        return unless @config.sentinel_auto_provision
        return unless valid_auth?

        @provisioned = true

        project_id = detect_project_id
        return unless project_id

        client = Client.new(@config)
        client.provision(
          project_id: project_id,
          app_name: @config.app_name || @config.service
        )

        BrainzLab.debug_log("[Sentinel::Provisioner] Project provisioned: #{project_id}")
      rescue StandardError => e
        BrainzLab.debug_log("[Sentinel::Provisioner] Provisioning failed: #{e.message}")
      end

      private

      def valid_auth?
        key = @config.sentinel_api_key || @config.sentinel_master_key || @config.secret_key
        !key.nil? && !key.empty?
      end

      def detect_project_id
        ENV.fetch('BRAINZLAB_PROJECT_ID', nil)
      end
    end
  end
end
