# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'fileutils'

module BrainzLab
  module Flux
    class Provisioner
      CACHE_DIR = ENV.fetch('BRAINZLAB_CACHE_DIR') { File.join(Dir.home, '.brainzlab') }

      def initialize(config)
        @config = config
      end

      def ensure_project!
        return unless should_provision?

        # Try cached credentials first
        if (cached = load_cached_credentials)
          apply_credentials(cached)
          return cached
        end

        # Provision new project
        project = provision_project
        return unless project

        # Cache and apply credentials
        cache_credentials(project)
        apply_credentials(project)

        project
      end

      private

      def should_provision?
        # Already have credentials
        return false if @config.flux_ingest_key.to_s.strip.length.positive?
        return false if @config.flux_api_key.to_s.strip.length.positive?

        # Need auto_provision enabled
        return false unless @config.flux_auto_provision

        # Need app_name for project name
        return false unless @config.app_name.to_s.strip.length.positive?

        # Need master key for provisioning
        return false unless @config.flux_master_key.to_s.strip.length.positive?

        # Need flux_url
        return false unless @config.flux_url.to_s.strip.length.positive?

        true
      end

      def provision_project
        BrainzLab.debug_log('[Flux] Auto-provisioning project...')

        uri = URI.parse("#{@config.flux_url}/api/v1/projects/provision")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['X-Master-Key'] = @config.flux_master_key
        request['User-Agent'] = "brainzlab-sdk/#{BrainzLab::VERSION}"
        request.body = {
          name: @config.app_name,
          environment: @config.environment
        }.to_json

        response = http.request(request)

        if response.is_a?(Net::HTTPSuccess)
          data = JSON.parse(response.body, symbolize_names: true)
          BrainzLab.debug_log('[Flux] Project provisioned successfully')
          data
        else
          BrainzLab.debug_log("[Flux] Provisioning failed: #{response.code} - #{response.body}")
          nil
        end
      rescue StandardError => e
        BrainzLab.debug_log("[Flux] Provisioning error: #{e.message}")
        nil
      end

      def load_cached_credentials
        path = cache_file_path
        return nil unless File.exist?(path)

        data = JSON.parse(File.read(path), symbolize_names: true)

        # Validate cached data has required keys
        return nil unless data[:ingest_key]

        data
      rescue StandardError => e
        BrainzLab.debug_log("[Flux] Failed to load cached credentials: #{e.message}")
        nil
      end

      def cache_credentials(project)
        FileUtils.mkdir_p(CACHE_DIR)
        File.write(cache_file_path, JSON.generate(project))
      rescue StandardError => e
        BrainzLab.debug_log("[Flux] Failed to cache credentials: #{e.message}")
      end

      def cache_file_path
        File.join(CACHE_DIR, "#{@config.app_name}.flux.json")
      end

      def apply_credentials(project)
        @config.flux_ingest_key = project[:ingest_key]
        @config.flux_api_key = project[:api_key]
      end
    end
  end
end
