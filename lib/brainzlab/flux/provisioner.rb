# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module BrainzLab
  module Flux
    class Provisioner
      def initialize(config)
        @config = config
      end

      def ensure_project!
        return if (@config.flux_ingest_key && !@config.flux_ingest_key.to_s.empty?) ||
                  (@config.flux_api_key && !@config.flux_api_key.to_s.empty?)
        return unless @config.flux_url && !@config.flux_url.to_s.empty?
        return unless @config.secret_key && !@config.secret_key.to_s.empty?

        BrainzLab.debug_log("[Flux] Auto-provisioning project...")
        provision_project
      end

      private

      def provision_project
        uri = URI.parse("#{@config.flux_url}/api/v1/projects/provision")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 30

        request = Net::HTTP::Post.new(uri.path)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@config.secret_key}"
        request["User-Agent"] = "brainzlab-sdk/#{BrainzLab::VERSION}"
        request.body = {
          name: @config.service || "default",
          environment: @config.environment
        }.to_json

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body)
          @config.flux_ingest_key = data["ingest_key"]
          @config.flux_api_key = data["api_key"]
          BrainzLab.debug_log("[Flux] Project provisioned successfully")
        else
          BrainzLab.debug_log("[Flux] Provisioning failed: #{response.code} - #{response.body}")
        end
      rescue => e
        BrainzLab.debug_log("[Flux] Provisioning error: #{e.message}")
      end
    end
  end
end
