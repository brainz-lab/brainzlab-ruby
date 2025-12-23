# frozen_string_literal: true

module BrainzLab
  module Flux
    class Buffer
      MAX_EVENTS = 100
      MAX_METRICS = 100
      FLUSH_INTERVAL = 5 # seconds

      def initialize(client)
        @client = client
        @events = []
        @metrics = []
        @mutex = Mutex.new
        @last_flush = Time.now

        start_flush_thread
      end

      def add(type, data)
        @mutex.synchronize do
          case type
          when :event
            @events << data
          when :metric
            @metrics << data
          end

          flush_if_needed
        end
      end

      def flush!
        events_to_send = nil
        metrics_to_send = nil

        @mutex.synchronize do
          events_to_send = @events.dup
          metrics_to_send = @metrics.dup
          @events.clear
          @metrics.clear
          @last_flush = Time.now
        end

        send_batch(events_to_send, metrics_to_send)
      end

      def size
        @mutex.synchronize { @events.size + @metrics.size }
      end

      private

      def flush_if_needed
        should_flush = @events.size >= MAX_EVENTS ||
                       @metrics.size >= MAX_METRICS ||
                       Time.now - @last_flush >= FLUSH_INTERVAL

        flush_async if should_flush
      end

      def flush_async
        events_to_send = @events.dup
        metrics_to_send = @metrics.dup
        @events.clear
        @metrics.clear
        @last_flush = Time.now

        Thread.new do
          send_batch(events_to_send, metrics_to_send)
        end
      end

      def send_batch(events, metrics)
        return if events.empty? && metrics.empty?

        @client.send_batch(events: events, metrics: metrics)
      rescue => e
        BrainzLab.debug("[Flux] Batch send failed: #{e.message}")
      end

      def start_flush_thread
        Thread.new do
          loop do
            sleep FLUSH_INTERVAL
            begin
              flush! if size > 0
            rescue => e
              BrainzLab.debug("[Flux] Flush thread error: #{e.message}")
            end
          end
        end
      end
    end
  end
end
