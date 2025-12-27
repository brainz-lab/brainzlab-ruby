# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"

module BrainzLab
  module Dendrite
    class Client
      def initialize(config)
        @config = config
        @base_url = config.dendrite_url || "https://dendrite.brainzlab.ai"
      end

      # Connect a repository
      def connect_repository(url:, name: nil, branch: "main", **options)
        response = request(
          :post,
          "/api/v1/repositories",
          body: {
            url: url,
            name: name,
            branch: branch,
            **options
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("connect_repository", e)
        nil
      end

      # Trigger sync for a repository
      def sync_repository(repo_id)
        response = request(:post, "/api/v1/repositories/#{repo_id}/sync")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPAccepted)
      rescue StandardError => e
        log_error("sync_repository", e)
        false
      end

      # Get repository status
      def get_repository(repo_id)
        response = request(:get, "/api/v1/repositories/#{repo_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_repository", e)
        nil
      end

      # List repositories
      def list_repositories
        response = request(:get, "/api/v1/repositories")

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:repositories] || []
      rescue StandardError => e
        log_error("list_repositories", e)
        []
      end

      # Get wiki pages for a repository
      def get_wiki(repo_id)
        response = request(:get, "/api/v1/wiki/#{repo_id}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_wiki", e)
        nil
      end

      # Get a specific wiki page
      def get_wiki_page(repo_id, page_slug)
        response = request(:get, "/api/v1/wiki/#{repo_id}/#{CGI.escape(page_slug)}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("get_wiki_page", e)
        nil
      end

      # Semantic search across codebase
      def search(repo_id, query, limit: 10)
        response = request(
          :get,
          "/api/v1/search",
          params: { repo_id: repo_id, q: query, limit: limit }
        )

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:results] || []
      rescue StandardError => e
        log_error("search", e)
        []
      end

      # Ask a question about the codebase
      def ask(repo_id, question, session_id: nil)
        response = request(
          :post,
          "/api/v1/chat",
          body: {
            repo_id: repo_id,
            question: question,
            session_id: session_id
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("ask", e)
        nil
      end

      # Explain a specific file or function
      def explain(repo_id, path, symbol: nil)
        response = request(
          :post,
          "/api/v1/explain",
          body: {
            repo_id: repo_id,
            path: path,
            symbol: symbol
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("explain", e)
        nil
      end

      # Generate a diagram
      def generate_diagram(repo_id, type:, scope: nil)
        response = request(
          :post,
          "/api/v1/diagrams",
          body: {
            repo_id: repo_id,
            type: type,  # class, er, sequence, architecture
            scope: scope
          }
        )

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error("generate_diagram", e)
        nil
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
        http.read_timeout = 60  # Longer timeout for AI operations

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

        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"

        if use_service_key
          request["X-Service-Key"] = @config.dendrite_master_key || @config.secret_key
        else
          auth_key = @config.dendrite_api_key || @config.secret_key
          request["Authorization"] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Dendrite::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
