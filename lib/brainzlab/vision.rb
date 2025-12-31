# frozen_string_literal: true

require_relative 'vision/client'
require_relative 'vision/provisioner'

module BrainzLab
  module Vision
    class << self
      # Execute an autonomous AI task
      # @param instruction [String] Natural language instruction for the AI
      # @param start_url [String] URL to start from
      # @param model [String] LLM model to use (default: claude-sonnet-4)
      # @param browser_provider [String] Browser provider (default: local)
      # @param max_steps [Integer] Maximum steps to execute (default: 50)
      # @param timeout [Integer] Timeout in seconds (default: 300)
      # @return [Hash] Task result with extracted data
      def execute_task(instruction:, start_url:, model: nil, browser_provider: nil, max_steps: 50, timeout: 300)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled

        ensure_provisioned!
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.execute_task(
          instruction: instruction,
          start_url: start_url,
          model: model,
          browser_provider: browser_provider,
          max_steps: max_steps,
          timeout: timeout
        )
      end

      # Create a browser session
      # @param url [String] Optional initial URL
      # @param viewport [Hash] Viewport dimensions { width:, height: }
      # @param browser_provider [String] Browser provider to use
      # @return [Hash] Session info with session_id
      def create_session(url: nil, viewport: nil, browser_provider: nil)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled

        ensure_provisioned!
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.create_session(
          url: url,
          viewport: viewport,
          browser_provider: browser_provider
        )
      end

      # Perform an AI-powered action in a session
      # @param session_id [String] Session ID
      # @param instruction [String] Natural language instruction
      # @param model [String] LLM model to use
      # @return [Hash] Action result
      def ai_action(session_id:, instruction:, model: nil)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.ai_action(
          session_id: session_id,
          instruction: instruction,
          model: model
        )
      end

      # Perform a direct browser action
      # @param session_id [String] Session ID
      # @param action [Symbol] Action type (:click, :type, :scroll, etc.)
      # @param selector [String] Element selector
      # @param value [String] Value for type/fill actions
      # @return [Hash] Action result
      def perform(session_id:, action:, selector: nil, value: nil)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.perform(
          session_id: session_id,
          action: action,
          selector: selector,
          value: value
        )
      end

      # Extract structured data from the page
      # @param session_id [String] Session ID
      # @param schema [Hash] JSON schema for extraction
      # @param instruction [String] Optional instruction for extraction
      # @return [Hash] Extracted data
      def extract(session_id:, schema:, instruction: nil)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.extract(
          session_id: session_id,
          schema: schema,
          instruction: instruction
        )
      end

      # Close a browser session
      # @param session_id [String] Session ID
      # @return [Hash] Close result
      def close_session(session_id:)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.close_session(session_id: session_id)
      end

      # Take a screenshot
      # @param session_id [String] Session ID
      # @param full_page [Boolean] Capture full page (default: true)
      # @return [Hash] Screenshot data
      def screenshot(session_id:, full_page: true)
        config = BrainzLab.configuration
        return { error: 'Vision is not enabled' } unless config.vision_enabled
        return { error: 'Vision credentials not configured' } unless config.vision_valid?

        client.screenshot(session_id: session_id, full_page: full_page)
      end

      # Ensure project is auto-provisioned
      def ensure_provisioned!
        config = BrainzLab.configuration
        puts "[BrainzLab::Debug] Vision.ensure_provisioned! called, @provisioned=#{@provisioned}" if config.debug

        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def reset!
        @client = nil
        @provisioner = nil
        @provisioned = false
      end
    end
  end
end
