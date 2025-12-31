# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module BrainzLab
  module Flux
    class Client
      def initialize(config)
        @config = config
      end

      def send_event(event)
        post('/api/v1/events', event)
      end

      def send_events(events)
        post('/api/v1/events/batch', { events: events })
      end

      def send_metric(metric)
        post('/api/v1/metrics', metric)
      end

      def send_metrics(metrics)
        post('/api/v1/metrics/batch', { metrics: metrics })
      end

      def send_batch(events:, metrics:)
        post('/api/v1/flux/batch', { events: events, metrics: metrics })
      end

      private

      def post(path, body)
        uri = URI.parse("#{base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri.path)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{api_key}"
        request['User-Agent'] = "brainzlab-sdk/#{BrainzLab::VERSION}"
        request.body = body.to_json

        response = http.request(request)

        BrainzLab.debug("[Flux] Request failed: #{response.code} - #{response.body}") unless response.is_a?(Net::HTTPSuccess)

        response
      rescue StandardError => e
        BrainzLab.debug("[Flux] Request error: #{e.message}")
        nil
      end

      def base_url
        @config.flux_url
      end

      def api_key
        @config.flux_ingest_key || @config.flux_api_key
      end
    end
  end
end
