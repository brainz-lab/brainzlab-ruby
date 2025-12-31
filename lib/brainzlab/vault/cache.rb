# frozen_string_literal: true

module BrainzLab
  module Vault
    class Cache
      def initialize(ttl = 300)
        @ttl = ttl
        @store = {}
        @mutex = Mutex.new
      end

      def get(key)
        @mutex.synchronize do
          entry = @store[key]
          return nil unless entry
          return nil if expired?(entry)

          entry[:value]
        end
      end

      def set(key, value)
        @mutex.synchronize do
          @store[key] = {
            value: value,
            expires_at: Time.now + @ttl
          }
        end
        value
      end

      def has?(key)
        @mutex.synchronize do
          entry = @store[key]
          return false unless entry
          return false if expired?(entry)

          true
        end
      end

      def delete(key)
        @mutex.synchronize do
          @store.delete(key)
        end
      end

      def delete_pattern(pattern)
        @mutex.synchronize do
          regex = Regexp.new(pattern.gsub('*', '.*'))
          @store.delete_if { |k, _| k.match?(regex) }
        end
      end

      def clear!
        @mutex.synchronize do
          @store.clear
        end
      end

      def size
        @mutex.synchronize do
          cleanup_expired!
          @store.size
        end
      end

      private

      def expired?(entry)
        entry[:expires_at] < Time.now
      end

      def cleanup_expired!
        now = Time.now
        @store.delete_if { |_, entry| entry[:expires_at] < now }
      end
    end
  end
end
