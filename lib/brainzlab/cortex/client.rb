# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'cgi'

module BrainzLab
  module Cortex
    class Client
      def initialize(config)
        @config = config
        @base_url = config.cortex_url || 'https://cortex.brainzlab.ai'
      end

      # Evaluate a single flag
      def evaluate(flag_name, context: {})
        response = request(
          :post,
          '/api/v1/evaluate',
          body: {
            flag: flag_name,
            context: context
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:result]
      rescue StandardError => e
        log_error('evaluate', e)
        nil
      end

      # Evaluate multiple flags at once
      def evaluate_all(context: {})
        response = request(
          :post,
          '/api/v1/evaluate/batch',
          body: { context: context }
        )

        return {} unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:flags] || {}
      rescue StandardError => e
        log_error('evaluate_all', e)
        {}
      end

      # List all flags
      def list
        response = request(:get, '/api/v1/flags')

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:flags] || []
      rescue StandardError => e
        log_error('list', e)
        []
      end

      # Get flag details
      def get_flag(flag_name)
        response = request(:get, "/api/v1/flags/#{CGI.escape(flag_name.to_s)}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('get_flag', e)
        nil
      end

      def provision(project_id:, app_name:)
        response = request(
          :post,
          '/api/v1/projects/provision',
          body: { project_id: project_id, app_name: app_name },
          use_service_key: true
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error('provision', e)
        false
      end

      private

      def request(method, path, headers: {}, body: nil, params: nil, use_service_key: false)
        uri = URI.parse("#{@base_url}#{path}")

        uri.query = URI.encode_www_form(params) if params

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10

        request = case method
                  when :get
                    Net::HTTP::Get.new(uri)
                  when :post
                    Net::HTTP::Post.new(uri)
                  when :put
                    Net::HTTP::Put.new(uri)
                  when :delete
                    Net::HTTP::Delete.new(uri)
                  end

        # Set headers
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'

        if use_service_key
          request['X-Service-Key'] = @config.cortex_master_key || @config.secret_key
        else
          auth_key = @config.cortex_api_key || @config.secret_key
          request['Authorization'] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }

        # Set body
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Cortex::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
