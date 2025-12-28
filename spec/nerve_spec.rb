# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Nerve do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.nerve_enabled = true
    end

    described_class.reset!

    stub_request(:get, %r{nerve\.brainzlab\.ai/api/v1/jobs})
      .to_return(status: 200, body: '{"jobs": [{"id": "job_123", "job_class": "SendEmailJob", "status": "completed"}]}')

    stub_request(:post, "https://nerve.brainzlab.ai/api/v1/jobs")
      .to_return(status: 201, body: '{"tracked": true}')

    stub_request(:post, "https://nerve.brainzlab.ai/api/v1/jobs/failures")
      .to_return(status: 201, body: '{"tracked": true}')

    stub_request(:get, "https://nerve.brainzlab.ai/api/v1/queues")
      .to_return(status: 200, body: '{"queues": [{"name": "default", "size": 10, "latency": 5.2}]}')

    stub_request(:get, %r{nerve\.brainzlab\.ai/api/v1/stats})
      .to_return(status: 200, body: '{"processed": 1000, "failed": 5, "retried": 20}')
  end

  describe ".jobs" do
    it "lists jobs" do
      result = described_class.jobs

      expect(result).to be_an(Array)
      expect(result.first[:job_class]).to eq("SendEmailJob")
    end

    it "filters by status" do
      described_class.jobs(status: "failed")

      expect(WebMock).to have_requested(:get, "https://nerve.brainzlab.ai/api/v1/jobs")
        .with(query: hash_including("status" => "failed"))
    end

    it "returns empty array when nerve is disabled" do
      BrainzLab.configuration.nerve_enabled = false

      result = described_class.jobs

      expect(result).to eq([])
    end
  end

  describe ".queues" do
    it "lists all queues" do
      result = described_class.queues

      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq("default")
      expect(result.first[:size]).to eq(10)
    end
  end

  describe ".report_success" do
    it "reports a successful job execution" do
      result = described_class.report_success(
        job_class: "ProcessOrderJob",
        job_id: "job_456",
        queue: "critical",
        started_at: Time.now - 5
      )

      expect(result).to be true
      expect(WebMock).to have_requested(:post, "https://nerve.brainzlab.ai/api/v1/jobs")
        .with { |req|
          body = JSON.parse(req.body)
          body["job_class"] == "ProcessOrderJob" && body["queue"] == "critical" && body["status"] == "completed"
        }
    end
  end

  describe ".report_failure" do
    it "reports a job failure" do
      error = StandardError.new("Something went wrong")
      error.set_backtrace(["line1", "line2"])

      result = described_class.report_failure(
        job_class: "ProcessOrderJob",
        job_id: "job_456",
        queue: "critical",
        error: error
      )

      expect(result).to be true
      expect(WebMock).to have_requested(:post, "https://nerve.brainzlab.ai/api/v1/jobs/failures")
        .with { |req|
          body = JSON.parse(req.body)
          body["error_class"] == "StandardError" &&
            body["error_message"] == "Something went wrong"
        }
    end
  end

  describe ".stats" do
    it "gets job statistics" do
      result = described_class.stats

      expect(result[:processed]).to eq(1000)
      expect(result[:failed]).to eq(5)
    end

    it "filters by time period" do
      described_class.stats(period: "24h")

      expect(WebMock).to have_requested(:get, "https://nerve.brainzlab.ai/api/v1/stats")
        .with(query: hash_including("period" => "24h"))
    end
  end

  describe ".reset!" do
    it "resets all nerve state" do
      described_class.jobs

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
    end
  end
end
