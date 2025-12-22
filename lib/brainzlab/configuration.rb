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
                  :scrub_fields,
                  :logger,
                  :instrument_http,
                  :http_ignore_hosts,
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

      # Filtering
      @scrub_fields = %i[password password_confirmation token api_key secret]

      # Internal logger for debugging SDK issues
      @logger = nil

      # Instrumentation
      @instrument_http = false
      @http_ignore_hosts = %w[localhost 127.0.0.1]

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
