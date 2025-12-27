# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "fileutils"

module BrainzLab
  module Vision
    class Provisioner
      CACHE_DIR = ENV.fetch("BRAINZLAB_CACHE_DIR") { File.join(Dir.home, ".brainzlab") }

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
          log_debug("Checking Vision provision conditions:")
          log_debug("  vision_auto_provision: #{@config.vision_auto_provision}")
          log_debug("  app_name: '#{@config.app_name}'")
          log_debug("  vision_api_key set: #{@config.vision_api_key.to_s.strip.length > 0}")
          log_debug("  vision_ingest_key set: #{@config.vision_ingest_key.to_s.strip.length > 0}")
          log_debug("  vision_master_key set: #{@config.vision_master_key.to_s.strip.length > 0}")
        end

        return false unless @config.vision_auto_provision
        return false unless @config.app_name.to_s.strip.length > 0
        return false if @config.vision_api_key.to_s.strip.length > 0
        return false if @config.vision_ingest_key.to_s.strip.length > 0
        return false unless @config.vision_master_key.to_s.strip.length > 0

        log_debug("Will provision Vision project") if @config.debug
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
        uri = URI.parse("#{@config.vision_url}/api/v1/projects/provision")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["X-Master-Key"] = @config.vision_master_key
        request["User-Agent"] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate({
          name: @config.app_name,
          environment: @config.environment
        })

        response = execute(uri, request)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("Failed to provision Vision project: #{e.message}")
        nil
      end

      def load_cached_credentials
        path = cache_file_path
        return nil unless File.exist?(path)

        data = JSON.parse(File.read(path), symbolize_names: true)

        # Validate cached data has required keys
        return nil unless data[:ingest_key] || data[:api_key]

        data
      rescue StandardError => e
        log_error("Failed to load cached Vision credentials: #{e.message}")
        nil
      end

      def cache_credentials(project)
        FileUtils.mkdir_p(CACHE_DIR)
        File.write(cache_file_path, JSON.generate(project))
      rescue StandardError => e
        log_error("Failed to cache Vision credentials: #{e.message}")
      end

      def cache_file_path
        File.join(CACHE_DIR, "#{@config.app_name}.vision.json")
      end

      def apply_credentials(project)
        @config.vision_ingest_key = project[:ingest_key]
        @config.vision_api_key = project[:api_key]

        # Also set service name from app_name if not already set
        @config.service ||= @config.app_name
      end

      def execute(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
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
