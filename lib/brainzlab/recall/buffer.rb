# frozen_string_literal: true

require "concurrent"

module BrainzLab
  module Recall
    class Buffer
      def initialize(config, client)
        @config = config
        @client = client
        @buffer = Concurrent::Array.new
        @mutex = Mutex.new
        @flush_thread = nil
        @shutdown = false

        start_flush_thread
        setup_at_exit
      end

      def push(log_entry)
        @buffer.push(log_entry)
        flush if @buffer.size >= @config.recall_buffer_size
      end

      def flush
        return if @buffer.empty?

        entries = nil
        @mutex.synchronize do
          entries = @buffer.dup
          @buffer.clear
        end

        return if entries.nil? || entries.empty?

        @client.send_batch(entries)
      end

      def shutdown
        @shutdown = true
        @flush_thread&.kill
        flush
      end

      private

      def start_flush_thread
        @flush_thread = Thread.new do
          loop do
            break if @shutdown

            sleep(@config.recall_flush_interval)
            flush unless @shutdown
          end
        end
        @flush_thread.abort_on_exception = false
      end

      def setup_at_exit
        at_exit { shutdown }
      end
    end
  end
end
