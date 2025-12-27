# frozen_string_literal: true

require_relative "cortex/client"
require_relative "cortex/cache"
require_relative "cortex/provisioner"

module BrainzLab
  module Cortex
    class << self
      # Check if a feature flag is enabled
      # @param flag_name [String, Symbol] The flag name
      # @param context [Hash] Evaluation context (user, attributes, etc.)
      # @return [Boolean] True if the flag is enabled
      #
      # @example
      #   if BrainzLab::Cortex.enabled?(:new_checkout, user: current_user)
      #     render_new_checkout
      #   end
      #
      def enabled?(flag_name, **context)
        result = get(flag_name, **context)
        result == true || result == "true"
      end

      # Check if a feature flag is disabled
      # @param flag_name [String, Symbol] The flag name
      # @param context [Hash] Evaluation context
      # @return [Boolean] True if the flag is disabled
      def disabled?(flag_name, **context)
        !enabled?(flag_name, **context)
      end

      # Get the value of a feature flag
      # @param flag_name [String, Symbol] The flag name
      # @param context [Hash] Evaluation context
      # @param default [Object] Default value if flag not found
      # @return [Object] The flag value
      #
      # @example
      #   limit = BrainzLab::Cortex.get(:rate_limit, user: current_user, default: 100)
      #
      def get(flag_name, default: nil, **context)
        return default unless module_enabled?

        ensure_provisioned!
        return default unless BrainzLab.configuration.cortex_valid?

        flag_key = flag_name.to_s
        merged_context = merge_context(context)
        cache_key = build_cache_key(flag_key, merged_context)

        # Check cache first
        if BrainzLab.configuration.cortex_cache_enabled && cache.has?(cache_key)
          return cache.get(cache_key)
        end

        result = client.evaluate(flag_key, context: merged_context)

        if result.nil?
          default
        else
          cache.set(cache_key, result) if BrainzLab.configuration.cortex_cache_enabled
          result
        end
      end

      # Get the variant for an A/B test flag
      # @param flag_name [String, Symbol] The flag name
      # @param context [Hash] Evaluation context
      # @param default [String] Default variant if flag not found
      # @return [String, nil] The variant name
      #
      # @example
      #   variant = BrainzLab::Cortex.variant(:checkout_experiment, user: current_user)
      #   case variant
      #   when "control" then render_control
      #   when "treatment_a" then render_treatment_a
      #   when "treatment_b" then render_treatment_b
      #   end
      #
      def variant(flag_name, default: nil, **context)
        result = get(flag_name, **context)
        result.is_a?(String) ? result : default
      end

      # Get all flags for a context
      # @param context [Hash] Evaluation context
      # @return [Hash] All flag values
      #
      # @example
      #   flags = BrainzLab::Cortex.all(user: current_user)
      #   flags[:new_checkout]  # => true
      #   flags[:rate_limit]    # => 200
      #
      def all(**context)
        return {} unless module_enabled?

        ensure_provisioned!
        return {} unless BrainzLab.configuration.cortex_valid?

        merged_context = merge_context(context)
        client.evaluate_all(context: merged_context)
      end

      # List all flag definitions
      # @return [Array<Hash>] List of flag metadata
      def list_flags
        return [] unless module_enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.cortex_valid?

        client.list
      end

      # Get a flag's configuration
      # @param flag_name [String, Symbol] The flag name
      # @return [Hash, nil] Flag configuration
      def flag_config(flag_name)
        return nil unless module_enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.cortex_valid?

        client.get_flag(flag_name.to_s)
      end

      # Clear the flag cache
      def clear_cache!
        cache.clear!
      end

      # === Context Helpers ===

      # Set default context for all evaluations in current request
      # @param context [Hash] Context to merge
      def set_context(**context)
        Thread.current[:cortex_context] = (Thread.current[:cortex_context] || {}).merge(context)
      end

      # Clear the current context
      def clear_context!
        Thread.current[:cortex_context] = nil
      end

      # Evaluate flags with a temporary context
      # @param context [Hash] Temporary context
      def with_context(**context)
        previous = Thread.current[:cortex_context]
        Thread.current[:cortex_context] = (previous || {}).merge(context)
        yield
      ensure
        Thread.current[:cortex_context] = previous
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
        @cache ||= Cache.new(BrainzLab.configuration.cortex_cache_ttl)
      end

      def reset!
        @client = nil
        @provisioner = nil
        @cache = nil
        @provisioned = false
        Thread.current[:cortex_context] = nil
      end

      private

      def module_enabled?
        BrainzLab.configuration.cortex_enabled
      end

      def merge_context(context)
        default_context = BrainzLab.configuration.cortex_default_context || {}
        thread_context = Thread.current[:cortex_context] || {}

        # Also include user from BrainzLab context if available
        brainzlab_context = {}
        if BrainzLab::Context.current.user
          brainzlab_context[:user] = BrainzLab::Context.current.user
        end

        # Normalize user context
        merged = default_context.merge(brainzlab_context).merge(thread_context).merge(context)

        # Convert user object to hash if needed
        if merged[:user].respond_to?(:id)
          merged[:user] = {
            id: merged[:user].id.to_s,
            email: merged[:user].try(:email),
            name: merged[:user].try(:name)
          }.compact
        end

        merged
      end

      def build_cache_key(flag_name, context)
        # Include relevant context in cache key
        user_id = context.dig(:user, :id) || context[:user_id]
        env = BrainzLab.configuration.environment

        parts = [env, flag_name]
        parts << "u:#{user_id}" if user_id
        parts.join(":")
      end
    end
  end
end
