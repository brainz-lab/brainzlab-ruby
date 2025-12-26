# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module BrainzLab
  module Signal
    class Client
      def initialize(config)
        @config = config
      end

      def send_alert(alert)
        post("/api/v1/alerts", alert)
      end

      def send_notification(notification)
        post("/api/v1/notifications", notification)
      end

      def trigger_rule(payload)
        post("/api/v1/rules/trigger", payload)
      end

      private

      def post(path, body)
        uri = URI.parse("#{base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri.path)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{api_key}"
        request["User-Agent"] = "brainzlab-sdk/#{BrainzLab::VERSION}"
        request.body = body.to_json

        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          BrainzLab.debug_log("[Signal] Request failed: #{response.code} - #{response.body}")
        end

        response
      rescue => e
        BrainzLab.debug_log("[Signal] Request error: #{e.message}")
        nil
      end

      def base_url
        @config.signal_url
      end

      def api_key
        @config.signal_auth_key
      end
    end
  end
end
