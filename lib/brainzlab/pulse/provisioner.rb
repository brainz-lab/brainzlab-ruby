# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

module BrainzLab
  module Pulse
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
        return false unless @config.pulse_auto_provision
        return false unless @config.app_name.to_s.strip.length.positive?
        # Only skip if pulse_api_key is already set
        return false if @config.pulse_api_key.to_s.strip.length.positive?
        return false unless @config.pulse_master_key.to_s.strip.length.positive?

        true
      end

      def provision_project
        uri = URI.parse("#{@config.pulse_url}/api/v1/projects/provision")
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['X-Master-Key'] = @config.pulse_master_key
        request['User-Agent'] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate({ name: @config.app_name })

        response = execute(uri, request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("Failed to provision Pulse project: #{e.message}")
        nil
      end

      def load_cached_credentials
        path = cache_file_path
        return nil unless File.exist?(path)

        data = JSON.parse(File.read(path), symbolize_names: true)

        # Validate cached data has required keys
        return nil unless data[:api_key]

        data
      rescue StandardError => e
        log_error("Failed to load cached Pulse credentials: #{e.message}")
        nil
      end

      def cache_credentials(project)
        FileUtils.mkdir_p(CACHE_DIR)
        File.write(cache_file_path, JSON.generate(project))
      rescue StandardError => e
        log_error("Failed to cache Pulse credentials: #{e.message}")
      end

      def cache_file_path
        File.join(CACHE_DIR, "#{@config.app_name}.pulse.json")
      end

      def apply_credentials(project)
        @config.pulse_api_key = project[:api_key]

        # Also set service name from app_name if not already set
        @config.service ||= @config.app_name
      end

      def execute(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10
        http.request(request)
      end

      def log_error(message)
        return unless @config.logger

        @config.logger.error("[BrainzLab::Pulse] #{message}")
      end
    end
  end
end
