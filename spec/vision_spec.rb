# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Vision do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.vision_enabled = true
      config.vision_url = "https://vision.brainzlab.ai"
      config.vision_default_model = "claude-sonnet-4"
    end

    described_class.reset!

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_task")
      .to_return(status: 200, body: '{"task_id": "task_123", "status": "pending"}')

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_session_create")
      .to_return(status: 200, body: '{"session_id": "sess_123", "browser_id": "browser_456"}')

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_session_close")
      .to_return(status: 200, body: '{"closed": true}')

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_ai_action")
      .to_return(status: 200, body: '{"success": true}')

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_perform")
      .to_return(status: 200, body: '{"success": true}')

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_extract")
      .to_return(status: 200, body: '{"data": {"title": "Example Page", "items": []}}')

    stub_request(:post, "https://vision.brainzlab.ai/mcp/tools/vision_screenshot")
      .to_return(status: 200, body: '{"image_url": "https://vision.brainzlab.ai/screenshots/123.png"}')
  end

  describe ".execute_task" do
    it "creates an autonomous browser task" do
      result = described_class.execute_task(
        instruction: "Go to amazon.com and find the price of MacBook Pro",
        start_url: "https://amazon.com"
      )

      expect(result[:task_id]).to eq("task_123")
      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_task")
        .with { |req|
          body = JSON.parse(req.body)
          body["instruction"] == "Go to amazon.com and find the price of MacBook Pro" &&
            body["start_url"] == "https://amazon.com"
        }
    end

    it "returns error when vision is disabled" do
      BrainzLab.configuration.vision_enabled = false

      result = described_class.execute_task(instruction: "Do something", start_url: "https://example.com")

      expect(result[:error]).to include("not enabled")
    end
  end

  describe ".create_session" do
    it "creates a browser session" do
      result = described_class.create_session(url: "https://example.com")

      expect(result[:session_id]).to eq("sess_123")
      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_session_create")
        .with { |req|
          body = JSON.parse(req.body)
          body["url"] == "https://example.com"
        }
    end

    it "accepts viewport configuration" do
      described_class.create_session(viewport: { width: 1920, height: 1080 })

      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_session_create")
        .with { |req|
          body = JSON.parse(req.body)
          body["viewport"]["width"] == 1920
        }
    end
  end

  describe ".close_session" do
    it "closes a browser session" do
      result = described_class.close_session(session_id: "sess_123")

      expect(result[:closed]).to be true
      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_session_close")
    end
  end

  describe ".ai_action" do
    it "performs an AI action in session" do
      result = described_class.ai_action(session_id: "sess_123", instruction: "Click the login button")

      expect(result[:success]).to be true
      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_ai_action")
        .with { |req|
          body = JSON.parse(req.body)
          body["instruction"] == "Click the login button" &&
            body["session_id"] == "sess_123"
        }
    end
  end

  describe ".perform" do
    it "performs a direct browser action" do
      result = described_class.perform(session_id: "sess_123", action: :click, selector: "#button")

      expect(result[:success]).to be true
      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_perform")
        .with { |req|
          body = JSON.parse(req.body)
          body["action"] == "click" && body["selector"] == "#button"
        }
    end
  end

  describe ".extract" do
    it "extracts data from page" do
      result = described_class.extract(session_id: "sess_123", schema: { title: "string", items: "array" })

      expect(result[:data][:title]).to eq("Example Page")
    end

    it "accepts extraction instruction" do
      described_class.extract(session_id: "sess_123", schema: {}, instruction: "Get all product prices")

      expect(WebMock).to have_requested(:post, "https://vision.brainzlab.ai/mcp/tools/vision_extract")
        .with { |req|
          body = JSON.parse(req.body)
          body["instruction"] == "Get all product prices"
        }
    end
  end

  describe ".screenshot" do
    it "takes a screenshot" do
      result = described_class.screenshot(session_id: "sess_123")

      expect(result[:image_url]).to include("screenshots")
    end
  end

  describe ".reset!" do
    it "resets all vision state" do
      described_class.create_session

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end
end
