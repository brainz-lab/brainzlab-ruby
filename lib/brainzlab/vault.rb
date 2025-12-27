# frozen_string_literal: true

require_relative "vault/client"
require_relative "vault/cache"
require_relative "vault/provisioner"

module BrainzLab
  module Vault
    class << self
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
        if BrainzLab.configuration.vault_cache_enabled && cache.has?(cache_key)
          return cache.get(cache_key)
        end

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
        if result && BrainzLab.configuration.vault_cache_enabled
          cache.delete("#{env}:#{key}")
        end

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
        if result && BrainzLab.configuration.vault_cache_enabled
          cache.delete_pattern("*:#{key}")
        end

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
        return value if value.present?

        # Fall back to environment variable
        if env_var
          ENV[env_var]
        else
          ENV[key]
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
