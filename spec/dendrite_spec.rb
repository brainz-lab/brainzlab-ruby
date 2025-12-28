# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Dendrite do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.dendrite_enabled = true
    end

    described_class.reset!

    stub_request(:post, "https://dendrite.brainzlab.ai/api/v1/repositories")
      .to_return(status: 201, body: '{"id": "repo_123", "name": "My API", "status": "syncing"}')

    stub_request(:post, %r{dendrite\.brainzlab\.ai/api/v1/repositories/.*/sync})
      .to_return(status: 202, body: '{"syncing": true}')

    stub_request(:get, "https://dendrite.brainzlab.ai/api/v1/repositories")
      .to_return(status: 200, body: '{"repositories": [{"id": "repo_123", "name": "My API"}]}')

    stub_request(:get, %r{dendrite\.brainzlab\.ai/api/v1/repositories/.*})
      .to_return(status: 200, body: '{"id": "repo_123", "name": "My API", "status": "ready"}')

    stub_request(:get, %r{dendrite\.brainzlab\.ai/api/v1/wiki/.*})
      .to_return(status: 200, body: '{"pages": [{"slug": "models/user", "title": "User Model"}]}')

    stub_request(:get, %r{dendrite\.brainzlab\.ai/api/v1/search})
      .to_return(status: 200, body: '{"results": [{"path": "app/models/user.rb", "score": 0.95}]}')

    stub_request(:post, "https://dendrite.brainzlab.ai/api/v1/chat")
      .to_return(status: 200, body: '{"answer": "The payment flow works by...", "sources": []}')

    stub_request(:post, "https://dendrite.brainzlab.ai/api/v1/explain")
      .to_return(status: 200, body: '{"explanation": "This class handles user authentication..."}')

    stub_request(:post, "https://dendrite.brainzlab.ai/api/v1/diagrams")
      .to_return(status: 200, body: '{"mermaid": "classDiagram\\n  User --> Order"}')
  end

  describe ".connect" do
    it "connects a git repository" do
      result = described_class.connect(
        "https://github.com/org/repo",
        name: "My API",
        branch: "main"
      )

      expect(result[:id]).to eq("repo_123")
      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/repositories")
        .with { |req|
          body = JSON.parse(req.body)
          body["url"] == "https://github.com/org/repo" &&
            body["name"] == "My API" &&
            body["branch"] == "main"
        }
    end

    it "returns nil when dendrite is disabled" do
      BrainzLab.configuration.dendrite_enabled = false

      result = described_class.connect("https://github.com/org/repo")

      expect(result).to be_nil
    end
  end

  describe ".sync" do
    it "triggers a sync for a repository" do
      result = described_class.sync("repo_123")

      expect(result).to be true
      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/repositories/repo_123/sync")
    end
  end

  describe ".repositories" do
    it "lists all repositories" do
      result = described_class.repositories

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq("My API")
    end
  end

  describe ".repository" do
    it "gets repository details" do
      result = described_class.repository("repo_123")

      expect(result[:status]).to eq("ready")
    end
  end

  describe ".wiki" do
    it "gets wiki structure" do
      result = described_class.wiki("repo_123")

      expect(result[:pages]).to be_an(Array)
      expect(result[:pages].first[:slug]).to eq("models/user")
    end
  end

  describe ".search" do
    it "performs semantic search" do
      result = described_class.search("repo_123", "authentication flow")

      expect(result).to be_an(Array)
      expect(result.first[:path]).to eq("app/models/user.rb")
      expect(WebMock).to have_requested(:get, "https://dendrite.brainzlab.ai/api/v1/search")
        .with(query: hash_including("q" => "authentication flow", "repo_id" => "repo_123"))
    end

    it "respects limit parameter" do
      described_class.search("repo_123", "query", limit: 5)

      expect(WebMock).to have_requested(:get, "https://dendrite.brainzlab.ai/api/v1/search")
        .with(query: hash_including("limit" => "5"))
    end
  end

  describe ".ask" do
    it "asks a question about the codebase" do
      result = described_class.ask("repo_123", "How does the payment flow work?")

      expect(result[:answer]).to include("payment flow")
      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/chat")
        .with { |req|
          body = JSON.parse(req.body)
          body["repo_id"] == "repo_123" &&
            body["question"] == "How does the payment flow work?"
        }
    end

    it "supports session for follow-up questions" do
      described_class.ask("repo_123", "Tell me more", session_id: "session_123")

      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/chat")
        .with { |req|
          body = JSON.parse(req.body)
          body["session_id"] == "session_123"
        }
    end
  end

  describe ".explain" do
    it "explains a file" do
      result = described_class.explain("repo_123", "app/models/user.rb")

      expect(result[:explanation]).to include("authentication")
      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/explain")
        .with { |req|
          body = JSON.parse(req.body)
          body["path"] == "app/models/user.rb"
        }
    end

    it "explains a specific symbol" do
      described_class.explain("repo_123", "app/models/user.rb", symbol: "authenticate")

      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/explain")
        .with { |req|
          body = JSON.parse(req.body)
          body["symbol"] == "authenticate"
        }
    end
  end

  describe ".diagram" do
    it "generates a diagram" do
      result = described_class.diagram("repo_123", type: :class)

      expect(result[:mermaid]).to include("classDiagram")
      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/diagrams")
        .with { |req|
          body = JSON.parse(req.body)
          body["type"] == "class"
        }
    end

    it "supports scoped diagrams" do
      described_class.diagram("repo_123", type: :er, scope: "User")

      expect(WebMock).to have_requested(:post, "https://dendrite.brainzlab.ai/api/v1/diagrams")
        .with { |req|
          body = JSON.parse(req.body)
          body["scope"] == "User"
        }
    end
  end

  describe ".reset!" do
    it "resets all dendrite state" do
      described_class.repositories

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end
end
