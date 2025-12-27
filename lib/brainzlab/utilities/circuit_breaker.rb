# frozen_string_literal: true

module BrainzLab
  module Utilities
    # Circuit breaker pattern implementation for resilient external calls
    # Integrates with Flux for metrics and Reflex for error tracking
    #
    # States:
    # - :closed - Normal operation, requests pass through
    # - :open - Failing, requests are rejected immediately
    # - :half_open - Testing, limited requests allowed to check recovery
    #
    # @example Basic usage
    #   breaker = BrainzLab::Utilities::CircuitBreaker.new(
    #     name: "external_api",
    #     failure_threshold: 5,
    #     recovery_timeout: 30
    #   )
    #
    #   breaker.call do
    #     external_api.request
    #   end
    #
    # @example With fallback
    #   breaker.call(fallback: -> { cached_value }) do
    #     external_api.request
    #   end
    #
    class CircuitBreaker
      STATES = %i[closed open half_open].freeze

      attr_reader :name, :state, :failure_count, :success_count, :last_failure_at

      def initialize(name:, failure_threshold: 5, success_threshold: 2, recovery_timeout: 30, timeout: nil, exclude_exceptions: [])
        @name = name
        @failure_threshold = failure_threshold
        @success_threshold = success_threshold
        @recovery_timeout = recovery_timeout
        @timeout = timeout
        @exclude_exceptions = exclude_exceptions

        @state = :closed
        @failure_count = 0
        @success_count = 0
        @last_failure_at = nil
        @mutex = Mutex.new
      end

      # Execute a block with circuit breaker protection
      def call(fallback: nil)
        check_state_transition!

        case @state
        when :open
          track_rejected
          if fallback
            fallback.respond_to?(:call) ? fallback.call : fallback
          else
            raise CircuitOpenError, "Circuit '#{@name}' is open"
          end
        when :closed, :half_open
          execute_with_protection(fallback) { yield }
        end
      end

      # Force the circuit to a specific state
      def force_state!(new_state)
        raise ArgumentError, "Invalid state: #{new_state}" unless STATES.include?(new_state)

        @mutex.synchronize do
          @state = new_state
          @failure_count = 0 if new_state == :closed
          @success_count = 0 if new_state == :half_open
        end

        track_state_change(new_state)
      end

      # Reset the circuit breaker
      def reset!
        force_state!(:closed)
        @last_failure_at = nil
      end

      # Get circuit status
      def status
        {
          name: @name,
          state: @state,
          failure_count: @failure_count,
          success_count: @success_count,
          failure_threshold: @failure_threshold,
          success_threshold: @success_threshold,
          last_failure_at: @last_failure_at,
          recovery_timeout: @recovery_timeout
        }
      end

      # Check if circuit is allowing requests
      def available?
        check_state_transition!
        @state != :open
      end

      # Class-level registry of circuit breakers
      class << self
        def registry
          @registry ||= {}
        end

        def get(name)
          registry[name.to_s]
        end

        def register(name, **options)
          registry[name.to_s] = new(name: name, **options)
        end

        def call(name, **options, &block)
          breaker = get(name) || register(name, **options)
          breaker.call(**options.slice(:fallback), &block)
        end

        def reset_all!
          registry.each_value(&:reset!)
        end

        def status_all
          registry.transform_values(&:status)
        end
      end

      private

      def execute_with_protection(fallback)
        result = if @timeout
                   Timeout.timeout(@timeout) { yield }
                 else
                   yield
                 end

        record_success
        result
      rescue *excluded_exceptions => e
        # Don't count excluded exceptions as failures
        raise
      rescue StandardError => e
        record_failure(e)

        if fallback
          fallback.respond_to?(:call) ? fallback.call : fallback
        else
          raise
        end
      end

      def record_success
        @mutex.synchronize do
          if @state == :half_open
            @success_count += 1
            if @success_count >= @success_threshold
              transition_to(:closed)
            end
          else
            @failure_count = 0
          end
        end

        track_success
      end

      def record_failure(error)
        @mutex.synchronize do
          @failure_count += 1
          @last_failure_at = Time.now

          if @state == :half_open
            transition_to(:open)
          elsif @failure_count >= @failure_threshold
            transition_to(:open)
          end
        end

        track_failure(error)
      end

      def check_state_transition!
        return unless @state == :open && @last_failure_at

        if Time.now - @last_failure_at >= @recovery_timeout
          @mutex.synchronize do
            transition_to(:half_open) if @state == :open
          end
        end
      end

      def transition_to(new_state)
        old_state = @state
        @state = new_state

        case new_state
        when :closed
          @failure_count = 0
          @success_count = 0
        when :half_open
          @success_count = 0
        when :open
          # Keep failure count for debugging
        end

        track_state_change(new_state, old_state)
      end

      def excluded_exceptions
        @exclude_exceptions.empty? ? [] : @exclude_exceptions
      end

      # Metrics tracking

      def track_success
        return unless BrainzLab.configuration.flux_effectively_enabled?

        BrainzLab::Flux.increment("circuit_breaker.success", tags: { name: @name, state: @state.to_s })
      end

      def track_failure(error)
        return unless BrainzLab.configuration.flux_effectively_enabled?

        BrainzLab::Flux.increment("circuit_breaker.failure", tags: {
          name: @name,
          state: @state.to_s,
          error_class: error.class.name
        })
      end

      def track_rejected
        return unless BrainzLab.configuration.flux_effectively_enabled?

        BrainzLab::Flux.increment("circuit_breaker.rejected", tags: { name: @name })
      end

      def track_state_change(new_state, old_state = nil)
        return unless BrainzLab.configuration.flux_effectively_enabled?

        BrainzLab::Flux.track("circuit_breaker.state_change", {
          name: @name,
          new_state: new_state.to_s,
          old_state: old_state&.to_s,
          failure_count: @failure_count
        })

        # Also add breadcrumb for debugging
        BrainzLab::Reflex.add_breadcrumb(
          "Circuit '#{@name}' transitioned to #{new_state}",
          category: "circuit_breaker",
          level: new_state == :open ? :warning : :info,
          data: { name: @name, old_state: old_state, new_state: new_state }
        )
      end

      # Error raised when circuit is open
      class CircuitOpenError < StandardError; end
    end
  end
end
