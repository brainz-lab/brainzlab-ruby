# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module BrainzLab
  module Vision
    class Client
      def initialize(config)
        @config = config
      end

      # Execute an autonomous AI task
      def execute_task(instruction:, start_url:, model: nil, browser_provider: nil, max_steps: 50, timeout: 300)
        payload = {
          instruction: instruction,
          start_url: start_url,
          max_steps: max_steps,
          timeout: timeout
        }
        payload[:model] = model if model
        payload[:browser_provider] = browser_provider if browser_provider

        post("/mcp/tools/vision_task", payload)
      end

      # Create a browser session
      def create_session(url: nil, viewport: nil, browser_provider: nil)
        payload = {}
        payload[:url] = url if url
        payload[:viewport] = viewport if viewport
        payload[:browser_provider] = browser_provider if browser_provider

        post("/mcp/tools/vision_session_create", payload)
      end

      # Perform an AI-powered action
      def ai_action(session_id:, instruction:, model: nil)
        payload = {
          session_id: session_id,
          instruction: instruction
        }
        payload[:model] = model if model

        post("/mcp/tools/vision_ai_action", payload)
      end

      # Perform a direct browser action
      def perform(session_id:, action:, selector: nil, value: nil)
        payload = {
          session_id: session_id,
          action: action.to_s
        }
        payload[:selector] = selector if selector
        payload[:value] = value if value

        post("/mcp/tools/vision_perform", payload)
      end

      # Extract structured data
      def extract(session_id:, schema:, instruction: nil)
        payload = {
          session_id: session_id,
          schema: schema
        }
        payload[:instruction] = instruction if instruction

        post("/mcp/tools/vision_extract", payload)
      end

      # Close a session
      def close_session(session_id:)
        post("/mcp/tools/vision_session_close", { session_id: session_id })
      end

      # Take a screenshot
      def screenshot(session_id:, full_page: true)
        post("/mcp/tools/vision_screenshot", {
          session_id: session_id,
          full_page: full_page
        })
      end

      private

      def post(path, payload)
        uri = URI.parse("#{@config.vision_url}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{auth_key}"
        request["User-Agent"] = "brainzlab-sdk-ruby/#{BrainzLab::VERSION}"
        request.body = JSON.generate(payload)

        response = execute(uri, request)

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body, symbolize_names: true)
        when Net::HTTPUnauthorized
          { error: "Unauthorized: Invalid API key" }
        when Net::HTTPForbidden
          { error: "Forbidden: Vision is not enabled for this project" }
        when Net::HTTPNotFound
          { error: "Not found: #{path}" }
        else
          { error: "HTTP #{response.code}: #{response.message}" }
        end
      rescue JSON::ParserError => e
        { error: "Invalid JSON response: #{e.message}" }
      rescue StandardError => e
        { error: "Request failed: #{e.message}" }
      end

      def auth_key
        @config.vision_ingest_key || @config.vision_api_key || @config.secret_key
      end

      def execute(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 300  # Long timeout for AI tasks
        http.request(request)
      end
    end
  end
end
