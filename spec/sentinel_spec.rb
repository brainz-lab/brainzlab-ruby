# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Sentinel do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.sentinel_enabled = true
    end

    described_class.reset!

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/hosts(?:\?|$)})
      .to_return(status: 200, body: '{"hosts": [{"id": "host_123", "name": "web-1", "status": "online"}]}')

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/hosts/[^/]+$})
      .to_return(status: 200, body: '{"id": "host_123", "name": "web-1", "cpu": 45.2, "memory": 68.5}')

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/hosts/.*/metrics})
      .to_return(status: 200, body: '{"cpu": [{"timestamp": "2024-01-01T00:00:00Z", "value": 45}], "memory": []}')

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/hosts/.*/processes})
      .to_return(status: 200, body: '{"processes": [{"pid": 1234, "name": "ruby", "cpu": 12.5}]}')

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/containers(?:\?|$)})
      .to_return(status: 200, body: '{"containers": [{"id": "cont_123", "name": "web", "status": "running"}]}')

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/containers/[^/]+$})
      .to_return(status: 200, body: '{"id": "cont_123", "name": "web", "cpu": 25.0}')

    stub_request(:get, %r{sentinel\.brainzlab\.ai/api/v1/alerts})
      .to_return(status: 200, body: '{"alerts": [{"id": "alert_123", "severity": "critical", "message": "High CPU"}]}')
  end

  describe ".hosts" do
    it "lists all hosts" do
      result = described_class.hosts

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq("web-1")
      expect(result.first[:status]).to eq("online")
    end

    it "filters by status" do
      described_class.hosts(status: "offline")

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/hosts")
        .with(query: hash_including("status" => "offline"))
    end

    it "returns empty array when sentinel is disabled" do
      BrainzLab.configuration.sentinel_enabled = false

      result = described_class.hosts

      expect(result).to eq([])
    end
  end

  describe ".host" do
    it "gets host details" do
      result = described_class.host("host_123")

      expect(result[:name]).to eq("web-1")
      expect(result[:cpu]).to eq(45.2)
    end
  end

  describe ".metrics" do
    it "gets host metrics" do
      result = described_class.metrics("host_123")

      expect(result[:cpu]).to be_an(Array)
    end

    it "filters by period" do
      described_class.metrics("host_123", period: "24h")

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/hosts/host_123/metrics")
        .with(query: hash_including("period" => "24h"))
    end

    it "filters by specific metrics" do
      described_class.metrics("host_123", metrics: ["cpu", "memory"])

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/hosts/host_123/metrics")
        .with(query: hash_including("metrics" => "cpu,memory"))
    end
  end

  describe ".processes" do
    it "gets top processes" do
      result = described_class.processes("host_123")

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq("ruby")
    end

    it "sorts by specified field" do
      described_class.processes("host_123", sort_by: "memory", limit: 10)

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/hosts/host_123/processes")
        .with(query: hash_including("sort_by" => "memory", "limit" => "10"))
    end
  end

  describe ".containers" do
    it "lists all containers" do
      result = described_class.containers

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq("web")
    end

    it "filters by host" do
      described_class.containers(host_id: "host_123")

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/containers")
        .with(query: hash_including("host_id" => "host_123"))
    end

    it "filters by status" do
      described_class.containers(status: "stopped")

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/containers")
        .with(query: hash_including("status" => "stopped"))
    end
  end

  describe ".container" do
    it "gets container details" do
      result = described_class.container("cont_123")

      expect(result[:name]).to eq("web")
      expect(result[:cpu]).to eq(25.0)
    end
  end

  describe ".alerts" do
    it "lists alerts" do
      result = described_class.alerts

      expect(result).to be_an(Array)
      expect(result.first[:severity]).to eq("critical")
    end

    it "filters by severity" do
      described_class.alerts(severity: "warning")

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/alerts")
        .with(query: hash_including("severity" => "warning"))
    end

    it "filters by host" do
      described_class.alerts(host_id: "host_123")

      expect(WebMock).to have_requested(:get, "https://sentinel.brainzlab.ai/api/v1/alerts")
        .with(query: hash_including("host_id" => "host_123"))
    end
  end

  describe ".reset!" do
    it "resets all sentinel state" do
      described_class.hosts

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end
end
