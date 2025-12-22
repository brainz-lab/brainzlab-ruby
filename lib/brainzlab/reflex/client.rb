# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module BrainzLab
  module Reflex
    class Client
      MAX_RETRIES = 3
      RETRY_DELAY = 0.5

      def initialize(config)
        @config = config
      end

      def send_error(payload)
        return unless @config.reflex_enabled && @config.reflex_valid?

        post("/api/v1/errors", payload)
      end

      def send_batch(payloads)
        return unless @config.reflex_enabled && @config.reflex_valid?
        return if payloads.empty?

        post("/api/v1/errors/batch", { errors: payloads })
      end

      private

      def post(path, body)
        uri = URI.join(@config.reflex_url, path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@config.reflex_auth_key}"
        request["User-Agent"] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate(body)

        execute_with_retry(uri, request)
      rescue StandardError => e
        log_error("Failed to send to Reflex: #{e.message}")
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
            log_error("Reflex API error: #{response.code} - #{response.body}")
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

        @config.logger.error("[BrainzLab::Reflex] #{message}")
      end

      class RetryableError < StandardError; end
    end
  end
end
