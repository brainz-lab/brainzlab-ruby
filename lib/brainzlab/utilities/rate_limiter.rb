# frozen_string_literal: true

module BrainzLab
  module Utilities
    # Rate limiter with support for sliding window and token bucket algorithms
    # Integrates with Flux for metrics tracking
    #
    # @example Basic usage
    #   limiter = BrainzLab::Utilities::RateLimiter.new(
    #     key: "api:user:123",
    #     limit: 100,
    #     window: 60  # seconds
    #   )
    #
    #   if limiter.allow?
    #     # proceed with request
    #   else
    #     # rate limited
    #   end
    #
    # @example With block
    #   BrainzLab::Utilities::RateLimiter.throttle("api:user:#{user.id}", limit: 100, window: 60) do
    #     # this block runs only if not rate limited
    #   end
    #
    class RateLimiter
      attr_reader :key, :limit, :window, :remaining, :reset_at

      def initialize(key:, limit:, window:, store: nil)
        @key = key
        @limit = limit
        @window = window
        @store = store || default_store
        @remaining = limit
        @reset_at = Time.now + window
      end

      # Check if request is allowed (doesn't consume a token)
      def allowed?
        count, reset = get_current_count
        count < @limit
      end

      # Check and consume a token
      def allow?
        count, reset = increment
        @remaining = [@limit - count, 0].max
        @reset_at = reset

        allowed = count <= @limit

        # Track metrics
        track_attempt(allowed)

        allowed
      end

      # Alias for allow?
      def throttle?
        !allow?
      end

      # Get current usage info
      def status
        count, reset = get_current_count
        {
          key: @key,
          limit: @limit,
          remaining: [@limit - count, 0].max,
          reset_at: reset,
          used: count
        }
      end

      # Reset the rate limit for this key
      def reset!
        @store.delete(@key)
        @remaining = @limit
        @reset_at = Time.now + @window
      end

      # Class method for quick throttling
      def self.throttle(key, limit:, window:, store: nil)
        limiter = new(key: key, limit: limit, window: window, store: store)

        if limiter.allow?
          yield if block_given?
          true
        else
          false
        end
      end

      # Check rate limit without incrementing
      def self.allowed?(key, limit:, window:, store: nil)
        limiter = new(key: key, limit: limit, window: window, store: store)
        limiter.allowed?
      end

      private

      def default_store
        @default_store ||= MemoryStore.new
      end

      def get_current_count
        bucket = current_bucket
        data = @store.get(@key) || { buckets: {}, created_at: Time.now.to_i }

        # Clean old buckets
        cutoff = Time.now.to_i - @window
        data[:buckets].delete_if { |k, _| k.to_i < cutoff }

        count = data[:buckets].values.sum
        reset = Time.at(Time.now.to_i + @window - (Time.now.to_i % @window))

        [count, reset]
      end

      def increment
        bucket = current_bucket
        data = @store.get(@key) || { buckets: {}, created_at: Time.now.to_i }

        # Clean old buckets
        cutoff = Time.now.to_i - @window
        data[:buckets].delete_if { |k, _| k.to_i < cutoff }

        # Increment current bucket
        data[:buckets][bucket] ||= 0
        data[:buckets][bucket] += 1

        # Store with TTL
        @store.set(@key, data, ttl: @window * 2)

        count = data[:buckets].values.sum
        reset = Time.at(Time.now.to_i + @window - (Time.now.to_i % @window))

        [count, reset]
      end

      def current_bucket
        # Use 1-second buckets for sliding window
        Time.now.to_i.to_s
      end

      def track_attempt(allowed)
        return unless BrainzLab.configuration.flux_effectively_enabled?

        if allowed
          BrainzLab::Flux.increment("rate_limiter.allowed", tags: { key: sanitize_key(@key) })
        else
          BrainzLab::Flux.increment("rate_limiter.denied", tags: { key: sanitize_key(@key) })
        end
      end

      def sanitize_key(key)
        # Remove user-specific identifiers for aggregation
        key.gsub(/:\d+/, ":*").gsub(/:[a-f0-9-]{36}/, ":*")
      end

      # Simple in-memory store (for development/single-instance)
      class MemoryStore
        def initialize
          @data = {}
          @mutex = Mutex.new
        end

        def get(key)
          @mutex.synchronize do
            entry = @data[key]
            return nil unless entry
            return nil if entry[:expires_at] && Time.now > entry[:expires_at]

            entry[:value]
          end
        end

        def set(key, value, ttl: nil)
          @mutex.synchronize do
            @data[key] = {
              value: value,
              expires_at: ttl ? Time.now + ttl : nil
            }
          end
        end

        def delete(key)
          @mutex.synchronize do
            @data.delete(key)
          end
        end

        def clear!
          @mutex.synchronize do
            @data.clear
          end
        end
      end

      # Redis store adapter
      class RedisStore
        def initialize(redis)
          @redis = redis
        end

        def get(key)
          data = @redis.get("brainzlab:ratelimit:#{key}")
          return nil unless data

          JSON.parse(data, symbolize_names: true)
        rescue StandardError
          nil
        end

        def set(key, value, ttl: nil)
          full_key = "brainzlab:ratelimit:#{key}"
          if ttl
            @redis.setex(full_key, ttl, value.to_json)
          else
            @redis.set(full_key, value.to_json)
          end
        end

        def delete(key)
          @redis.del("brainzlab:ratelimit:#{key}")
        end
      end
    end
  end
end
