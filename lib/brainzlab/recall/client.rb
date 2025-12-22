# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module BrainzLab
  module Recall
    class Client
      MAX_RETRIES = 3
      RETRY_DELAY = 0.5

      def initialize(config)
        @config = config
        @uri = URI.parse(config.recall_url)
      end

      def send_log(log_entry)
        return unless @config.recall_enabled && @config.valid?

        post("/api/v1/log", log_entry)
      end

      def send_batch(log_entries)
        return unless @config.recall_enabled && @config.valid?
        return if log_entries.empty?

        post("/api/v1/logs", { logs: log_entries })
      end

      private

      def post(path, body)
        uri = URI.join(@config.recall_url, path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{@config.secret_key}"
        request["User-Agent"] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate(body)

        execute_with_retry(uri, request)
      rescue StandardError => e
        log_error("Failed to send to Recall: #{e.message}")
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
            log_error("Recall API error: #{response.code} - #{response.body}")
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

        @config.logger.error("[BrainzLab] #{message}")
      end

      class RetryableError < StandardError; end
    end
  end
end
