# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Synapse do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.synapse_enabled = true
    end

    described_class.reset!

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/projects(?:\?|$)})
      .to_return(status: 200, body: '{"projects": [{"id": "proj_123", "name": "My App", "status": "running"}]}')

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/projects/[^/]+$})
      .to_return(status: 200, body: '{"id": "proj_123", "name": "My App", "repos": []}')

    stub_request(:post, "https://synapse.brainzlab.ai/api/v1/projects")
      .to_return(status: 201, body: '{"id": "proj_456", "name": "New Project"}')

    stub_request(:post, %r{synapse\.brainzlab\.ai/api/v1/projects/.*/up})
      .to_return(status: 202, body: '{}')

    stub_request(:post, %r{synapse\.brainzlab\.ai/api/v1/projects/.*/down})
      .to_return(status: 202, body: '{}')

    stub_request(:post, %r{synapse\.brainzlab\.ai/api/v1/projects/.*/restart})
      .to_return(status: 202, body: '{}')

    stub_request(:post, %r{synapse\.brainzlab\.ai/api/v1/projects/.*/deploy})
      .to_return(status: 202, body: '{"deployment_id": "deploy_123", "status": "pending"}')

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/deployments/.*})
      .to_return(status: 200, body: '{"id": "deploy_123", "status": "completed"}')

    stub_request(:post, "https://synapse.brainzlab.ai/api/v1/tasks")
      .to_return(status: 201, body: '{"id": "task_123", "status": "pending"}')

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/tasks/[^/]+$})
      .to_return(status: 200, body: '{"id": "task_123", "description": "Add auth", "status": "in_progress"}')

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/tasks/.*/status})
      .to_return(status: 200, body: '{"status": "in_progress", "progress": 45}')

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/tasks(?:\?|$)})
      .to_return(status: 200, body: '{"tasks": [{"id": "task_123", "status": "completed"}]}')

    stub_request(:post, %r{synapse\.brainzlab\.ai/api/v1/tasks/.*/cancel})
      .to_return(status: 200, body: '{}')

    stub_request(:get, %r{synapse\.brainzlab\.ai/api/v1/projects/.*/logs})
      .to_return(status: 200, body: '{"logs": "Starting server...\\nListening on port 3000"}')

    stub_request(:post, %r{synapse\.brainzlab\.ai/api/v1/projects/.*/exec})
      .to_return(status: 200, body: '{"output": "Migration completed", "exit_code": 0}')
  end

  describe ".projects" do
    it "lists all projects" do
      result = described_class.projects

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq("My App")
    end

    it "filters by status" do
      described_class.projects(status: "stopped")

      expect(WebMock).to have_requested(:get, "https://synapse.brainzlab.ai/api/v1/projects")
        .with(query: hash_including("status" => "stopped"))
    end

    it "returns empty array when synapse is disabled" do
      BrainzLab.configuration.synapse_enabled = false

      result = described_class.projects

      expect(result).to eq([])
    end
  end

  describe ".project" do
    it "gets project details" do
      result = described_class.project("proj_123")

      expect(result[:name]).to eq("My App")
    end
  end

  describe ".create_project" do
    it "creates a new project" do
      result = described_class.create_project(
        name: "New App",
        repos: [{ url: "https://github.com/org/api", type: "rails" }],
        description: "A new application"
      )

      expect(result[:id]).to eq("proj_456")
      expect(WebMock).to have_requested(:post, "https://synapse.brainzlab.ai/api/v1/projects")
        .with { |req|
          body = JSON.parse(req.body)
          body["name"] == "New App" &&
            body["repos"].first["type"] == "rails"
        }
    end
  end

  describe ".up" do
    it "starts project containers" do
      result = described_class.up("proj_123")

      expect(result).to be true
      expect(WebMock).to have_requested(:post, "https://synapse.brainzlab.ai/api/v1/projects/proj_123/up")
    end
  end

  describe ".down" do
    it "stops project containers" do
      result = described_class.down("proj_123")

      expect(result).to be true
      expect(WebMock).to have_requested(:post, "https://synapse.brainzlab.ai/api/v1/projects/proj_123/down")
    end
  end

  describe ".restart" do
    it "restarts project containers" do
      result = described_class.restart("proj_123")

      expect(result).to be true
    end
  end

  describe ".deploy" do
    it "deploys to an environment" do
      result = described_class.deploy("proj_123", environment: :staging)

      expect(result[:deployment_id]).to eq("deploy_123")
      expect(WebMock).to have_requested(:post, "https://synapse.brainzlab.ai/api/v1/projects/proj_123/deploy")
        .with { |req|
          body = JSON.parse(req.body)
          body["environment"] == "staging"
        }
    end
  end

  describe ".deployment" do
    it "gets deployment status" do
      result = described_class.deployment("deploy_123")

      expect(result[:status]).to eq("completed")
    end
  end

  describe ".task" do
    it "creates an AI task" do
      result = described_class.task(
        project_id: "proj_123",
        description: "Add user authentication with OAuth",
        type: :feature,
        priority: :high
      )

      expect(result[:id]).to eq("task_123")
      expect(WebMock).to have_requested(:post, "https://synapse.brainzlab.ai/api/v1/tasks")
        .with { |req|
          body = JSON.parse(req.body)
          body["project_id"] == "proj_123" &&
            body["description"] == "Add user authentication with OAuth" &&
            body["type"] == "feature" &&
            body["priority"] == "high"
        }
    end
  end

  describe ".get_task" do
    it "gets task details" do
      result = described_class.get_task("task_123")

      expect(result[:description]).to eq("Add auth")
    end
  end

  describe ".task_status" do
    it "gets task status with progress" do
      result = described_class.task_status("task_123")

      expect(result[:status]).to eq("in_progress")
      expect(result[:progress]).to eq(45)
    end
  end

  describe ".tasks" do
    it "lists tasks" do
      result = described_class.tasks

      expect(result).to be_an(Array)
    end

    it "filters by project" do
      described_class.tasks(project_id: "proj_123")

      expect(WebMock).to have_requested(:get, "https://synapse.brainzlab.ai/api/v1/tasks")
        .with(query: hash_including("project_id" => "proj_123"))
    end
  end

  describe ".cancel_task" do
    it "cancels a running task" do
      result = described_class.cancel_task("task_123")

      expect(result).to be true
    end
  end

  describe ".logs" do
    it "gets container logs" do
      result = described_class.logs("proj_123")

      expect(result[:logs]).to include("Starting server")
    end

    it "filters by container" do
      described_class.logs("proj_123", container: "web", lines: 50)

      expect(WebMock).to have_requested(:get, "https://synapse.brainzlab.ai/api/v1/projects/proj_123/logs")
        .with(query: hash_including("container" => "web", "lines" => "50"))
    end
  end

  describe ".exec" do
    it "executes a command in container" do
      result = described_class.exec("proj_123", command: "rails db:migrate")

      expect(result[:output]).to eq("Migration completed")
      expect(result[:exit_code]).to eq(0)
    end
  end

  describe ".reset!" do
    it "resets all synapse state" do
      described_class.projects

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end
end
