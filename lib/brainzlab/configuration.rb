# frozen_string_literal: true

module BrainzLab
  class Configuration
    LEVELS = %i[debug info warn error fatal].freeze

    attr_accessor :secret_key,
                  :environment,
                  :service,
                  :host,
                  :commit,
                  :branch,
                  :app_name,
                  :debug,
                  :recall_enabled,
                  :recall_url,
                  :recall_min_level,
                  :recall_buffer_size,
                  :recall_flush_interval,
                  :recall_master_key,
                  :recall_auto_provision,
                  :reflex_enabled,
                  :reflex_url,
                  :reflex_api_key,
                  :reflex_master_key,
                  :reflex_auto_provision,
                  :reflex_excluded_exceptions,
                  :reflex_before_send,
                  :reflex_sample_rate,
                  :reflex_fingerprint,
                  :pulse_enabled,
                  :pulse_url,
                  :pulse_api_key,
                  :pulse_master_key,
                  :pulse_auto_provision,
                  :pulse_buffer_size,
                  :pulse_flush_interval,
                  :pulse_sample_rate,
                  :pulse_excluded_paths,
                  :scrub_fields,
                  :logger,
                  :instrument_http,
                  :instrument_active_record,
                  :instrument_redis,
                  :instrument_sidekiq,
                  :instrument_graphql,
                  :instrument_mongodb,
                  :instrument_elasticsearch,
                  :instrument_action_mailer,
                  :instrument_delayed_job,
                  :instrument_grape,
                  :http_ignore_hosts,
                  :redis_ignore_commands,
                  :log_formatter_enabled,
                  :log_formatter_colors,
                  :log_formatter_hide_assets,
                  :log_formatter_compact_assets,
                  :log_formatter_show_params

    def initialize
      # Authentication
      @secret_key = ENV["BRAINZLAB_SECRET_KEY"]

      # Environment
      @environment = ENV["BRAINZLAB_ENVIRONMENT"] || detect_environment
      @service = ENV["BRAINZLAB_SERVICE"]
      @host = ENV["BRAINZLAB_HOST"] || detect_host

      # App name for auto-provisioning
      @app_name = ENV["BRAINZLAB_APP_NAME"]

      # Git context
      @commit = ENV["GIT_COMMIT"] || ENV["COMMIT_SHA"] || detect_git_commit
      @branch = ENV["GIT_BRANCH"] || ENV["BRANCH_NAME"] || detect_git_branch

      # Debug mode - enables verbose logging
      @debug = ENV["BRAINZLAB_DEBUG"] == "true"

      # Recall settings
      @recall_enabled = true
      @recall_url = ENV["RECALL_URL"] || "https://recall.brainzlab.ai"
      @recall_min_level = :debug
      @recall_buffer_size = 50
      @recall_flush_interval = 5
      @recall_master_key = ENV["RECALL_MASTER_KEY"]
      @recall_auto_provision = true

      # Reflex settings
      @reflex_enabled = true
      @reflex_url = ENV["REFLEX_URL"] || "https://reflex.brainzlab.ai"
      @reflex_api_key = ENV["REFLEX_API_KEY"]
      @reflex_master_key = ENV["REFLEX_MASTER_KEY"]
      @reflex_auto_provision = true
      @reflex_excluded_exceptions = []
      @reflex_before_send = nil
      @reflex_sample_rate = nil
      @reflex_fingerprint = nil  # Custom fingerprint callback

      # Pulse settings
      @pulse_enabled = true
      @pulse_url = ENV["PULSE_URL"] || "https://pulse.brainzlab.ai"
      @pulse_api_key = ENV["PULSE_API_KEY"]
      @pulse_master_key = ENV["PULSE_MASTER_KEY"]
      @pulse_auto_provision = true
      @pulse_buffer_size = 50
      @pulse_flush_interval = 5
      @pulse_sample_rate = nil
      @pulse_excluded_paths = %w[/health /ping /up /assets]

      # Filtering
      @scrub_fields = %i[password password_confirmation token api_key secret]

      # Internal logger for debugging SDK issues
      @logger = nil

      # Instrumentation
      @instrument_http = true  # Enable HTTP client instrumentation (Net::HTTP, Faraday, HTTParty)
      @instrument_active_record = true  # AR breadcrumbs for Reflex
      @instrument_redis = true  # Redis command instrumentation
      @instrument_sidekiq = true  # Sidekiq job instrumentation
      @instrument_graphql = true  # GraphQL query instrumentation
      @instrument_mongodb = true  # MongoDB/Mongoid instrumentation
      @instrument_elasticsearch = true  # Elasticsearch instrumentation
      @instrument_action_mailer = true  # ActionMailer instrumentation
      @instrument_delayed_job = true  # Delayed::Job instrumentation
      @instrument_grape = true  # Grape API instrumentation
      @http_ignore_hosts = %w[localhost 127.0.0.1]
      @redis_ignore_commands = %w[ping info]  # Commands to skip tracking

      # Log formatter settings
      @log_formatter_enabled = true
      @log_formatter_colors = nil # auto-detect TTY
      @log_formatter_hide_assets = false
      @log_formatter_compact_assets = true
      @log_formatter_show_params = true
    end

    def recall_min_level=(level)
      level = level.to_sym
      raise ArgumentError, "Invalid level: #{level}" unless LEVELS.include?(level)

      @recall_min_level = level
    end

    def level_enabled?(level)
      LEVELS.index(level.to_sym) >= LEVELS.index(@recall_min_level)
    end

    def valid?
      !@secret_key.nil? && !@secret_key.empty?
    end

    def reflex_valid?
      key = reflex_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def reflex_auth_key
      reflex_api_key || secret_key
    end

    def pulse_valid?
      key = pulse_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def pulse_auth_key
      pulse_api_key || secret_key
    end

    def debug?
      @debug == true
    end

    def debug_log(message)
      return unless debug?

      log_message = "[BrainzLab::Debug] #{message}"
      if logger
        logger.debug(log_message)
      else
        $stderr.puts(log_message)
      end
    end

    private

    def detect_environment
      return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env)
      return ENV["RACK_ENV"] if ENV["RACK_ENV"]
      return ENV["RUBY_ENV"] if ENV["RUBY_ENV"]

      "development"
    end

    def detect_host
      require "socket"
      Socket.gethostname
    rescue StandardError
      nil
    end

    def detect_git_commit
      `git rev-parse HEAD 2>/dev/null`.strip.presence
    rescue StandardError
      nil
    end

    def detect_git_branch
      `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip.presence
    rescue StandardError
      nil
    end
  end
end
