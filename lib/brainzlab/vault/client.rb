# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module BrainzLab
  module Vault
    class Client
      def initialize(config)
        @config = config
        @base_url = config.vault_url || "https://vault.brainzlab.ai"
      end

      def get(key, environment:)
        response = request(
          :get,
          "/api/v1/secrets/#{CGI.escape(key)}",
          headers: { "X-Vault-Environment" => environment }
        )

        return nil unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:value]
      rescue StandardError => e
        log_error("get", e)
        nil
      end

      def set(key, value, environment:, description: nil, note: nil)
        body = {
          key: key,
          value: value,
          description: description,
          note: note
        }.compact

        response = request(
          :post,
          "/api/v1/secrets",
          headers: { "X-Vault-Environment" => environment },
          body: body
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error("set", e)
        false
      end

      def list(environment:)
        response = request(
          :get,
          "/api/v1/secrets",
          headers: { "X-Vault-Environment" => environment }
        )

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:secrets] || []
      rescue StandardError => e
        log_error("list", e)
        []
      end

      def delete(key)
        response = request(:delete, "/api/v1/secrets/#{CGI.escape(key)}")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNoContent)
      rescue StandardError => e
        log_error("delete", e)
        false
      end

      def export(environment:, format:)
        params = { format: format }
        response = request(
          :get,
          "/api/v1/sync/export",
          headers: { "X-Vault-Environment" => environment },
          params: params
        )

        return {} unless response.is_a?(Net::HTTPSuccess)

        case format
        when :json
          data = JSON.parse(response.body, symbolize_names: true)
          data[:secrets] || {}
        else
          response.body
        end
      rescue StandardError => e
        log_error("export", e)
        format == :json ? {} : ""
      end

      def provision(project_id:, app_name:)
        response = request(
          :post,
          "/api/v1/projects/provision",
          body: { project_id: project_id, app_name: app_name },
          use_service_key: true
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error("provision", e)
        false
      end

      private

      def request(method, path, headers: {}, body: nil, params: nil, use_service_key: false)
        uri = URI.parse("#{@base_url}#{path}")

        if params
          uri.query = URI.encode_www_form(params)
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 30

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
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"

        if use_service_key
          request["X-Service-Key"] = @config.vault_master_key || @config.secret_key
        else
          auth_key = @config.vault_api_key || @config.secret_key
          request["Authorization"] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }

        # Set body
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Vault::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
