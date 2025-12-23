# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module BrainzLab
  module Pulse
    class Client
      MAX_RETRIES = 3
      RETRY_DELAY = 0.5

      def initialize(config)
        @config = config
        @buffer = []
        @mutex = Mutex.new
        @flush_thread = nil
      end

      def send_trace(payload)
        return unless @config.pulse_enabled && @config.pulse_valid?

        if @config.pulse_buffer_size > 1
          buffer_trace(payload)
        else
          post("/api/v1/traces", payload)
        end
      end

      def send_batch(payloads)
        return unless @config.pulse_enabled && @config.pulse_valid?
        return if payloads.empty?

        post("/api/v1/traces/batch", { traces: payloads })
      end

      def send_metric(payload)
        return unless @config.pulse_enabled && @config.pulse_valid?

        post("/api/v1/metrics", payload)
      end

      def flush
        traces_to_send = nil

        @mutex.synchronize do
          return if @buffer.empty?

          traces_to_send = @buffer.dup
          @buffer.clear
        end

        send_batch(traces_to_send) if traces_to_send&.any?
      end

      private

      def buffer_trace(payload)
        should_flush = false

        @mutex.synchronize do
          @buffer << payload
          should_flush = @buffer.size >= @config.pulse_buffer_size
        end

        start_flush_timer unless @flush_thread&.alive?
        flush if should_flush
      end

      def start_flush_timer
        @flush_thread = Thread.new do
          loop do
            sleep(@config.pulse_flush_interval)
            flush
          end
        end
      end

      def post(path, body)
        uri = URI.join(@config.pulse_url, path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@config.pulse_auth_key}"
        request["User-Agent"] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate(body)

        execute_with_retry(uri, request)
      rescue StandardError => e
        log_error("Failed to send to Pulse: #{e.message}")
        nil
      end

      def execute_with_retry(uri, request)
        retries = 0
        begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 5
          http.read_timeout = 10

          response = http.request(request)

          case response.code.to_i
          when 200..299
            JSON.parse(response.body) rescue {}
          when 429, 500..599
            raise RetryableError, "Server error: #{response.code}"
          else
            log_error("Pulse API error: #{response.code} - #{response.body}")
            nil
          end
        rescue RetryableError, Net::OpenTimeout, Net::ReadTimeout => e
          retries += 1
          if retries <= MAX_RETRIES
            sleep(RETRY_DELAY * retries)
            retry
          end
          log_error("Failed after #{MAX_RETRIES} retries: #{e.message}")
          nil
        end
      end

      def log_error(message)
        return unless @config.logger

        @config.logger.error("[BrainzLab::Pulse] #{message}")
      end

      class RetryableError < StandardError; end
    end
  end
end
