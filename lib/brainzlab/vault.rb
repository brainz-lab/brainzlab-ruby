# frozen_string_literal: true

require_relative 'vault/client'
require_relative 'vault/cache'
require_relative 'vault/provisioner'

module BrainzLab
  module Vault
    class << self
      # Load all secrets into ENV like dotenv
      # This is the main method to use at app startup
      #
      # @param environment [String, Symbol] Environment to load (defaults to current)
      # @param overwrite [Boolean] Whether to overwrite existing ENV vars (default: false)
      # @param provider_keys [Boolean] Also load provider keys like OPENAI_API_KEY (default: true)
      # @return [Hash] The secrets that were loaded
      #
      # @example
      #   # In config/application.rb or an initializer
      #   BrainzLab::Vault.load!
      #
      #   # Load with options
      #   BrainzLab::Vault.load!(environment: :production, overwrite: true)
      #
      def load!(environment: nil, overwrite: false, provider_keys: true)
        return {} unless enabled?

        ensure_provisioned!
        return {} unless BrainzLab.configuration.vault_valid?

        env = environment&.to_s || BrainzLab.configuration.environment
        loaded = {}

        # Load regular secrets
        secrets = export(environment: env, format: :json)
        secrets.each do |key, value|
          key_str = key.to_s
          next unless overwrite || !ENV.key?(key_str)

          ENV[key_str] = value.to_s
          loaded[key_str] = value
          BrainzLab.debug_log("[Vault] Loaded #{key_str}")
        end

        # Load provider keys (OpenAI, Anthropic, etc.)
        if provider_keys
          provider_secrets = load_provider_keys!(overwrite: overwrite)
          loaded.merge!(provider_secrets)
        end

        BrainzLab.debug_log("[Vault] Loaded #{loaded.size} secrets into ENV")
        loaded
      rescue StandardError => e
        BrainzLab.debug_log("[Vault] Failed to load secrets: #{e.message}")
        {}
      end

      # Load provider keys (API keys for LLMs, etc.) into ENV
      #
      # @param overwrite [Boolean] Whether to overwrite existing ENV vars
      # @return [Hash] Provider keys that were loaded
      def load_provider_keys!(overwrite: false)
        return {} unless enabled? && BrainzLab.configuration.vault_valid?

        loaded = {}
        provider_keys = client.get_provider_keys

        provider_keys.each do |provider, key|
          env_var = "#{provider.to_s.upcase}_API_KEY"
          next unless overwrite || !ENV.key?(env_var)

          ENV[env_var] = key
          loaded[env_var] = key
          BrainzLab.debug_log("[Vault] Loaded provider key: #{env_var}")
        end

        loaded
      rescue StandardError => e
        BrainzLab.debug_log("[Vault] Failed to load provider keys: #{e.message}")
        {}
      end

      # Get a specific provider key
      # @param provider [String, Symbol] Provider name (openai, anthropic, etc.)
      # @param model_type [String] Model type (llm, embedding, etc.)
      # @return [String, nil] The API key
      def provider_key(provider, model_type: 'llm')
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.vault_valid?

        # Check ENV first
        env_var = "#{provider.to_s.upcase}_API_KEY"
        return ENV[env_var] if ENV[env_var] && !ENV[env_var].empty?

        # Fetch from Vault
        client.get_provider_key(provider: provider.to_s, model_type: model_type)
      end

      # Get a secret value
      # @param key [String] The secret key
      # @param environment [String, Symbol] Optional environment (defaults to current environment)
      # @param default [Object] Default value if secret not found
      # @return [String, nil] The secret value
      def get(key, environment: nil, default: nil)
        return default unless enabled?

        ensure_provisioned!
        return default unless BrainzLab.configuration.vault_valid?

        env = environment&.to_s || BrainzLab.configuration.environment
        cache_key = "#{env}:#{key}"

        # Check cache first
        return cache.get(cache_key) if BrainzLab.configuration.vault_cache_enabled && cache.has?(cache_key)

        value = client.get(key, environment: env)

        if value.nil?
          default
        else
          cache.set(cache_key, value) if BrainzLab.configuration.vault_cache_enabled
          value
        end
      end

      # Set a secret value
      # @param key [String] The secret key
      # @param value [String] The secret value
      # @param environment [String, Symbol] Optional environment (defaults to current environment)
      # @param description [String] Optional description
      # @param note [String] Optional version note
      # @return [Boolean] True if successful
      def set(key, value, environment: nil, description: nil, note: nil)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.vault_valid?

        env = environment&.to_s || BrainzLab.configuration.environment
        result = client.set(key, value, environment: env, description: description, note: note)

        # Invalidate cache
        cache.delete("#{env}:#{key}") if result && BrainzLab.configuration.vault_cache_enabled

        result
      end

      # List all secret keys
      # @param environment [String, Symbol] Optional environment
      # @return [Array<Hash>] List of secret metadata
      def list(environment: nil)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.vault_valid?

        env = environment&.to_s || BrainzLab.configuration.environment
        client.list(environment: env)
      end

      # Delete (archive) a secret
      # @param key [String] The secret key
      # @return [Boolean] True if successful
      def delete(key)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.vault_valid?

        result = client.delete(key)

        # Invalidate all environment caches for this key
        cache.delete_pattern("*:#{key}") if result && BrainzLab.configuration.vault_cache_enabled

        result
      end

      # Export all secrets for an environment
      # @param environment [String, Symbol] Environment to export
      # @param format [Symbol] Output format (:json, :dotenv, :shell)
      # @return [Hash, String] Exported secrets
      def export(environment: nil, format: :json)
        return {} unless enabled?

        ensure_provisioned!
        return {} unless BrainzLab.configuration.vault_valid?

        env = environment&.to_s || BrainzLab.configuration.environment
        client.export(environment: env, format: format)
      end

      # Fetch a secret with automatic fallback
      # @param key [String] The secret key
      # @param env_var [String] Environment variable to fall back to
      # @return [String, nil] The secret value
      def fetch(key, env_var: nil)
        value = get(key)
        return value if value && !value.to_s.empty?

        # Fall back to environment variable
        if env_var
          ENV.fetch(env_var, nil)
        else
          ENV.fetch(key, nil)
        end
      end

      # Clear the secret cache
      def clear_cache!
        cache.clear!
      end

      # Warm the cache with all secrets
      def warm_cache!(environment: nil)
        return unless enabled? && BrainzLab.configuration.vault_cache_enabled

        env = environment&.to_s || BrainzLab.configuration.environment
        secrets = export(environment: env, format: :json)

        secrets.each do |key, value|
          cache.set("#{env}:#{key}", value)
        end
      end

      # === INTERNAL ===

      def ensure_provisioned!
        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def cache
        @cache ||= Cache.new(BrainzLab.configuration.vault_cache_ttl)
      end

      def reset!
        @client = nil
        @provisioner = nil
        @cache = nil
        @provisioned = false
      end

      private

      def enabled?
        BrainzLab.configuration.vault_enabled
      end
    end
  end
end
