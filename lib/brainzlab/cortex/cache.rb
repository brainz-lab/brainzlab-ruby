# frozen_string_literal: true

module BrainzLab
  module Cortex
    class Cache
      def initialize(ttl = 60)
        @ttl = ttl
        @store = {}
        @timestamps = {}
        @mutex = Mutex.new
      end

      def get(key)
        @mutex.synchronize do
          return nil unless @store.key?(key)
          return nil if expired?(key)

          @store[key]
        end
      end

      def set(key, value)
        @mutex.synchronize do
          @store[key] = value
          @timestamps[key] = Time.now
        end
      end

      def has?(key)
        @mutex.synchronize do
          @store.key?(key) && !expired?(key)
        end
      end

      def delete(key)
        @mutex.synchronize do
          @store.delete(key)
          @timestamps.delete(key)
        end
      end

      def clear!
        @mutex.synchronize do
          @store.clear
          @timestamps.clear
        end
      end

      private

      def expired?(key)
        timestamp = @timestamps[key]
        return true unless timestamp

        Time.now - timestamp > @ttl
      end
    end
  end
end
