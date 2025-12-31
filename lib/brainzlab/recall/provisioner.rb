# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

module BrainzLab
  module Recall
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
        if @config.debug
          log_debug('Checking provision conditions:')
          log_debug("  recall_auto_provision: #{@config.recall_auto_provision}")
          log_debug("  app_name: '#{@config.app_name}'")
          log_debug("  secret_key set: #{@config.secret_key.to_s.strip.length.positive?}")
          log_debug("  recall_master_key set: #{@config.recall_master_key.to_s.strip.length.positive?}")
        end

        return false unless @config.recall_auto_provision
        return false unless @config.app_name.to_s.strip.length.positive?
        return false if @config.secret_key.to_s.strip.length.positive?
        return false unless @config.recall_master_key.to_s.strip.length.positive?

        log_debug('Will provision Recall project') if @config.debug
        true
      end

      def log_debug(message)
        if @config.logger
          @config.logger.info("[BrainzLab::Debug] #{message}")
        else
          puts "[BrainzLab::Debug] #{message}"
        end
      end

      def provision_project
        uri = URI.parse("#{@config.recall_url}/api/v1/projects/provision")
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request['X-Master-Key'] = @config.recall_master_key
        request['User-Agent'] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate({ name: @config.app_name })

        response = execute(uri, request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("Failed to provision Recall project: #{e.message}")
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
        log_error("Failed to load cached credentials: #{e.message}")
        nil
      end

      def cache_credentials(project)
        FileUtils.mkdir_p(CACHE_DIR)
        File.write(cache_file_path, JSON.generate(project))
      rescue StandardError => e
        log_error("Failed to cache credentials: #{e.message}")
      end

      def cache_file_path
        File.join(CACHE_DIR, "#{@config.app_name}.recall.json")
      end

      def apply_credentials(project)
        @config.secret_key = project[:ingest_key]

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

        @config.logger.error("[BrainzLab] #{message}")
      end
    end
  end
end
