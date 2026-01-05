# frozen_string_literal: true

module BrainzLab
  class Configuration
    LEVELS = %i[debug info warn error fatal].freeze

    # recall_min_level has a custom setter with validation
    attr_reader :recall_min_level

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
                  :flux_enabled,
                  :flux_url,
                  :flux_api_key,
                  :flux_ingest_key,
                  :flux_master_key,
                  :flux_auto_provision,
                  :flux_buffer_size,
                  :flux_flush_interval,
                  :signal_enabled,
                  :signal_url,
                  :signal_api_key,
                  :signal_ingest_key,
                  :signal_master_key,
                  :signal_auto_provision,
                  :vault_enabled,
                  :vault_url,
                  :vault_api_key,
                  :vault_master_key,
                  :vault_auto_provision,
                  :vault_cache_enabled,
                  :vault_cache_ttl,
                  :vault_auto_load,
                  :vault_load_provider_keys,
                  :vision_enabled,
                  :vision_url,
                  :vision_api_key,
                  :vision_ingest_key,
                  :vision_master_key,
                  :vision_auto_provision,
                  :vision_default_model,
                  :vision_default_browser_provider,
                  :cortex_enabled,
                  :cortex_url,
                  :cortex_api_key,
                  :cortex_master_key,
                  :cortex_auto_provision,
                  :cortex_cache_enabled,
                  :cortex_cache_ttl,
                  :cortex_default_context,
                  :beacon_enabled,
                  :beacon_url,
                  :beacon_api_key,
                  :beacon_master_key,
                  :beacon_auto_provision,
                  :nerve_enabled,
                  :nerve_url,
                  :nerve_api_key,
                  :nerve_master_key,
                  :nerve_auto_provision,
                  :dendrite_enabled,
                  :dendrite_url,
                  :dendrite_api_key,
                  :dendrite_master_key,
                  :dendrite_auto_provision,
                  :sentinel_enabled,
                  :sentinel_url,
                  :sentinel_api_key,
                  :sentinel_agent_key,
                  :sentinel_master_key,
                  :sentinel_auto_provision,
                  :synapse_enabled,
                  :synapse_url,
                  :synapse_api_key,
                  :synapse_master_key,
                  :synapse_auto_provision,
                  :scrub_fields,
                  :logger,
                  :instrument_http,
                  :instrument_active_record,
                  :instrument_redis,
                  :instrument_sidekiq,
                  :instrument_graphql,
                  :instrument_mongodb,
                  :instrument_elasticsearch,
                  :instrument_action_controller,
                  :instrument_action_view,
                  :instrument_action_mailer,
                  :instrument_active_job,
                  :instrument_active_support_cache,
                  :instrument_delayed_job,
                  :instrument_grape,
                  :instrument_solid_queue,
                  :instrument_good_job,
                  :instrument_resque,
                  :instrument_excon,
                  :instrument_typhoeus,
                  :instrument_dalli,
                  :instrument_aws,
                  :instrument_stripe,
                  :instrument_active_storage,
                  :instrument_action_cable,
                  :instrument_action_dispatch,
                  :instrument_rails_deprecation,
                  :instrument_action_mailbox,
                  :instrument_railties,
                  :http_ignore_hosts,
                  :redis_ignore_commands,
                  :log_formatter_enabled,
                  :log_formatter_colors,
                  :log_formatter_hide_assets,
                  :log_formatter_compact_assets,
                  :log_formatter_show_params,
                  :disable_self_tracking,
                  :devtools_enabled,
                  :devtools_error_page_enabled,
                  :devtools_debug_panel_enabled,
                  :devtools_allowed_environments,
                  :devtools_allowed_ips,
                  :devtools_asset_path,
                  :devtools_panel_position,
                  :devtools_expand_by_default,
                  :rails_instrumentation_handled_externally

    # Services that should not track themselves to avoid circular dependencies
    SELF_TRACKING_SERVICES = {
      'recall' => :recall_enabled,
      'reflex' => :reflex_enabled,
      'pulse' => :pulse_enabled,
      'flux' => :flux_enabled,
      'signal' => :signal_enabled
    }.freeze

    def initialize
      # Authentication
      @secret_key = ENV.fetch('BRAINZLAB_SECRET_KEY', nil)

      # Environment
      @environment = ENV['BRAINZLAB_ENVIRONMENT'] || detect_environment
      @service = ENV.fetch('BRAINZLAB_SERVICE', nil)
      @host = ENV['BRAINZLAB_HOST'] || detect_host

      # App name for auto-provisioning
      @app_name = ENV.fetch('BRAINZLAB_APP_NAME', nil)

      # Git context
      @commit = ENV['GIT_COMMIT'] || ENV['COMMIT_SHA'] || detect_git_commit
      @branch = ENV['GIT_BRANCH'] || ENV['BRANCH_NAME'] || detect_git_branch

      # Debug mode - enables verbose logging
      @debug = ENV['BRAINZLAB_DEBUG'] == 'true'

      # Disable self-tracking - prevents services from tracking to themselves
      # e.g., Recall won't log to itself, Reflex won't track errors to itself
      @disable_self_tracking = ENV.fetch('BRAINZLAB_DISABLE_SELF_TRACKING', 'true') == 'true'

      # Recall settings
      @recall_enabled = true
      @recall_url = ENV['RECALL_URL'] || detect_product_url('recall')
      @recall_min_level = :debug
      @recall_buffer_size = 50
      @recall_flush_interval = 5
      @recall_master_key = ENV.fetch('RECALL_MASTER_KEY', nil)
      @recall_auto_provision = true

      # Reflex settings
      @reflex_enabled = true
      @reflex_url = ENV['REFLEX_URL'] || detect_product_url('reflex')
      @reflex_api_key = ENV.fetch('REFLEX_API_KEY', nil)
      @reflex_master_key = ENV.fetch('REFLEX_MASTER_KEY', nil)
      @reflex_auto_provision = true
      @reflex_excluded_exceptions = []
      @reflex_before_send = nil
      @reflex_sample_rate = nil
      @reflex_fingerprint = nil # Custom fingerprint callback

      # Pulse settings
      @pulse_enabled = true
      @pulse_url = ENV['PULSE_URL'] || detect_product_url('pulse')
      @pulse_api_key = ENV.fetch('PULSE_API_KEY', nil)
      @pulse_master_key = ENV.fetch('PULSE_MASTER_KEY', nil)
      @pulse_auto_provision = true
      @pulse_buffer_size = 50
      @pulse_flush_interval = 5
      @pulse_sample_rate = nil
      @pulse_excluded_paths = %w[/health /ping /up /assets]

      # Flux settings
      @flux_enabled = true
      @flux_url = ENV['FLUX_URL'] || 'https://flux.brainzlab.ai'
      @flux_api_key = ENV.fetch('FLUX_API_KEY', nil)
      @flux_ingest_key = ENV.fetch('FLUX_INGEST_KEY', nil)
      @flux_master_key = ENV.fetch('FLUX_MASTER_KEY', nil)
      @flux_auto_provision = true
      @flux_buffer_size = 100
      @flux_flush_interval = 5

      # Signal settings
      @signal_enabled = true
      @signal_url = ENV['SIGNAL_URL'] || detect_product_url('signal')
      @signal_api_key = ENV.fetch('SIGNAL_API_KEY', nil)
      @signal_ingest_key = ENV.fetch('SIGNAL_INGEST_KEY', nil)
      @signal_master_key = ENV.fetch('SIGNAL_MASTER_KEY', nil)
      @signal_auto_provision = true

      # Vault settings
      @vault_enabled = true
      @vault_url = ENV['VAULT_URL'] || 'https://vault.brainzlab.ai'
      @vault_api_key = ENV.fetch('VAULT_API_KEY', nil)
      @vault_master_key = ENV.fetch('VAULT_MASTER_KEY', nil)
      @vault_auto_provision = true
      @vault_cache_enabled = true
      @vault_cache_ttl = 300 # 5 minutes
      @vault_auto_load = ENV.fetch('VAULT_AUTO_LOAD', 'false') == 'true' # Auto-load secrets into ENV
      @vault_load_provider_keys = true # Also load provider keys (OpenAI, etc.)

      # Vision settings (AI browser automation)
      @vision_enabled = true
      @vision_url = ENV['VISION_URL'] || 'https://vision.brainzlab.ai'
      @vision_api_key = ENV.fetch('VISION_API_KEY', nil)
      @vision_ingest_key = ENV.fetch('VISION_INGEST_KEY', nil)
      @vision_master_key = ENV.fetch('VISION_MASTER_KEY', nil)
      @vision_auto_provision = true
      @vision_default_model = ENV['VISION_DEFAULT_MODEL'] || 'claude-sonnet-4'
      @vision_default_browser_provider = ENV['VISION_DEFAULT_BROWSER_PROVIDER'] || 'local'

      # Cortex settings (feature flags)
      @cortex_enabled = true
      @cortex_url = ENV['CORTEX_URL'] || 'https://cortex.brainzlab.ai'
      @cortex_api_key = ENV.fetch('CORTEX_API_KEY', nil)
      @cortex_master_key = ENV.fetch('CORTEX_MASTER_KEY', nil)
      @cortex_auto_provision = true
      @cortex_cache_enabled = true
      @cortex_cache_ttl = 60 # 1 minute
      @cortex_default_context = {}

      # Beacon settings (uptime monitoring)
      @beacon_enabled = true
      @beacon_url = ENV['BEACON_URL'] || 'https://beacon.brainzlab.ai'
      @beacon_api_key = ENV.fetch('BEACON_API_KEY', nil)
      @beacon_master_key = ENV.fetch('BEACON_MASTER_KEY', nil)
      @beacon_auto_provision = true

      # Nerve settings (job monitoring)
      @nerve_enabled = true
      @nerve_url = ENV['NERVE_URL'] || 'https://nerve.brainzlab.ai'
      @nerve_api_key = ENV.fetch('NERVE_API_KEY', nil)
      @nerve_master_key = ENV.fetch('NERVE_MASTER_KEY', nil)
      @nerve_auto_provision = true

      # Dendrite settings (AI documentation)
      @dendrite_enabled = true
      @dendrite_url = ENV['DENDRITE_URL'] || 'https://dendrite.brainzlab.ai'
      @dendrite_api_key = ENV.fetch('DENDRITE_API_KEY', nil)
      @dendrite_master_key = ENV.fetch('DENDRITE_MASTER_KEY', nil)
      @dendrite_auto_provision = true

      # Sentinel settings (host monitoring)
      @sentinel_enabled = true
      @sentinel_url = ENV['SENTINEL_URL'] || 'https://sentinel.brainzlab.ai'
      @sentinel_api_key = ENV.fetch('SENTINEL_API_KEY', nil)
      @sentinel_agent_key = ENV.fetch('SENTINEL_AGENT_KEY', nil)
      @sentinel_master_key = ENV.fetch('SENTINEL_MASTER_KEY', nil)
      @sentinel_auto_provision = true

      # Synapse settings (AI development orchestration)
      @synapse_enabled = true
      @synapse_url = ENV['SYNAPSE_URL'] || 'https://synapse.brainzlab.ai'
      @synapse_api_key = ENV.fetch('SYNAPSE_API_KEY', nil)
      @synapse_master_key = ENV.fetch('SYNAPSE_MASTER_KEY', nil)
      @synapse_auto_provision = true

      # Filtering
      @scrub_fields = %i[password password_confirmation token api_key secret]

      # Internal logger for debugging SDK issues
      @logger = nil

      # Instrumentation
      @instrument_http = true # Enable HTTP client instrumentation (Net::HTTP, Faraday, HTTParty)
      @instrument_active_record = true # AR breadcrumbs for Reflex
      @instrument_redis = true # Redis command instrumentation
      @instrument_sidekiq = true  # Sidekiq job instrumentation
      @instrument_graphql = true  # GraphQL query instrumentation
      @instrument_mongodb = true  # MongoDB/Mongoid instrumentation
      @instrument_elasticsearch = true  # Elasticsearch instrumentation
      @instrument_action_controller = true  # ActionController instrumentation (requests, redirects, filters)
      @instrument_action_view = true  # ActionView instrumentation (templates, partials, collections)
      @instrument_action_mailer = true  # ActionMailer instrumentation
      @instrument_active_job = true  # ActiveJob instrumentation (enqueue, perform, retry, discard)
      @instrument_active_support_cache = true  # ActiveSupport::Cache instrumentation (read, write, fetch)
      @instrument_delayed_job = true # Delayed::Job instrumentation
      @instrument_grape = true # Grape API instrumentation
      @instrument_solid_queue = true # Solid Queue job instrumentation
      @instrument_good_job = true # GoodJob instrumentation
      @instrument_resque = true # Resque instrumentation
      @instrument_excon = true # Excon HTTP client instrumentation
      @instrument_typhoeus = true # Typhoeus HTTP client instrumentation
      @instrument_dalli = true # Dalli/Memcached instrumentation
      @instrument_aws = true # AWS SDK instrumentation
      @instrument_stripe = true # Stripe API instrumentation
      @instrument_active_storage = true # ActiveStorage instrumentation (uploads, downloads, transforms)
      @instrument_action_cable = true # ActionCable WebSocket instrumentation
      @instrument_action_dispatch = true # ActionDispatch instrumentation (middleware, redirects, requests)
      @instrument_rails_deprecation = true # Rails deprecation warnings tracking
      @instrument_action_mailbox = true # ActionMailbox inbound email processing instrumentation
      @instrument_railties = true # Railties config initializer loading instrumentation
      @http_ignore_hosts = %w[localhost 127.0.0.1]
      @redis_ignore_commands = %w[ping info] # Commands to skip tracking

      # Log formatter settings
      @log_formatter_enabled = true
      @log_formatter_colors = nil # auto-detect TTY
      @log_formatter_hide_assets = false
      @log_formatter_compact_assets = true
      @log_formatter_show_params = true

      # DevTools settings (development error page and debug panel)
      @devtools_enabled = true
      @devtools_error_page_enabled = true
      @devtools_debug_panel_enabled = true
      @devtools_allowed_environments = %w[development test]
      @devtools_allowed_ips = ['127.0.0.1', '::1', '172.16.0.0/12', '192.168.0.0/16', '10.0.0.0/8']
      @devtools_asset_path = '/__brainzlab__'
      @devtools_panel_position = 'bottom-right'
      @devtools_expand_by_default = false

      # Rails instrumentation delegation
      # When true, brainzlab-rails gem handles Rails-specific instrumentation
      # SDK will only install non-Rails instrumentation (HTTP clients, Redis, etc.)
      @rails_instrumentation_handled_externally = false
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

    def flux_valid?
      key = flux_ingest_key || flux_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def flux_auth_key
      flux_ingest_key || flux_api_key || secret_key
    end

    def signal_valid?
      key = signal_ingest_key || signal_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def signal_auth_key
      signal_ingest_key || signal_api_key || secret_key
    end

    def vault_valid?
      key = vault_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def vault_auth_key
      vault_api_key || secret_key
    end

    def vision_valid?
      key = vision_ingest_key || vision_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def vision_auth_key
      vision_ingest_key || vision_api_key || secret_key
    end

    def beacon_valid?
      key = beacon_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def beacon_auth_key
      beacon_api_key || secret_key
    end

    def nerve_valid?
      key = nerve_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def nerve_auth_key
      nerve_api_key || secret_key
    end

    def cortex_valid?
      key = cortex_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def cortex_auth_key
      cortex_api_key || secret_key
    end

    def dendrite_valid?
      key = dendrite_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def dendrite_auth_key
      dendrite_api_key || secret_key
    end

    def sentinel_valid?
      key = sentinel_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def sentinel_auth_key
      sentinel_api_key || secret_key
    end

    def synapse_valid?
      key = synapse_api_key || secret_key
      !key.nil? && !key.empty?
    end

    def synapse_auth_key
      synapse_api_key || secret_key
    end

    def debug?
      @debug == true
    end

    # Check if recall is effectively enabled (considering self-tracking)
    def recall_effectively_enabled?
      return false unless @recall_enabled
      return true unless @disable_self_tracking

      # Disable if this is the Recall service itself
      normalized_app_name = @app_name.to_s.downcase.strip
      normalized_app_name != 'recall'
    end

    # Check if reflex is effectively enabled (considering self-tracking)
    def reflex_effectively_enabled?
      return false unless @reflex_enabled
      return true unless @disable_self_tracking

      # Disable if this is the Reflex service itself
      normalized_app_name = @app_name.to_s.downcase.strip
      normalized_app_name != 'reflex'
    end

    # Check if pulse is effectively enabled (considering self-tracking)
    def pulse_effectively_enabled?
      return false unless @pulse_enabled
      return true unless @disable_self_tracking

      # Disable if this is the Pulse service itself
      normalized_app_name = @app_name.to_s.downcase.strip
      normalized_app_name != 'pulse'
    end

    # Check if flux is effectively enabled (considering self-tracking)
    def flux_effectively_enabled?
      return false unless @flux_enabled
      return true unless @disable_self_tracking

      # Disable if this is the Flux service itself
      normalized_app_name = @app_name.to_s.downcase.strip
      normalized_app_name != 'flux'
    end

    # Check if signal is effectively enabled (considering self-tracking)
    def signal_effectively_enabled?
      return false unless @signal_enabled
      return true unless @disable_self_tracking

      # Disable if this is the Signal service itself
      normalized_app_name = @app_name.to_s.downcase.strip
      normalized_app_name != 'signal'
    end

    def debug_log(message)
      return unless debug?

      log_message = "[BrainzLab::Debug] #{message}"
      if logger
        logger.debug(log_message)
      else
        warn(log_message)
      end
    end

    private

    def detect_environment
      return ::Rails.env.to_s if defined?(::Rails) && ::Rails.respond_to?(:env)
      return ENV['RACK_ENV'] if ENV['RACK_ENV']
      return ENV['RUBY_ENV'] if ENV['RUBY_ENV']

      'development'
    end

    def detect_host
      require 'socket'
      Socket.gethostname
    rescue StandardError
      nil
    end

    def detect_git_commit
      result = `git rev-parse HEAD 2>/dev/null`.strip
      result.empty? ? nil : result
    rescue StandardError
      nil
    end

    def detect_git_branch
      result = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      result.empty? ? nil : result
    rescue StandardError
      nil
    end

    def detect_product_url(product)
      # In development, use .localhost domains (works with Traefik)
      # In production, use the real brainzlab.ai domains
      if development?
        "http://#{product}.localhost"
      else
        "https://#{product}.brainzlab.ai"
      end
    end

    def development?
      @environment == 'development' ||
        ENV['RAILS_ENV'] == 'development' ||
        ENV['RACK_ENV'] == 'development'
    end
  end
end
