# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Pulse do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.pulse_enabled = true
      config.pulse_api_key = "test_pulse_key"  # Set to skip auto-provisioning
      config.pulse_buffer_size = 1  # Disable buffering for tests
    end

    described_class.reset!

    stub_request(:post, "https://pulse.brainzlab.ai/api/v1/traces")
      .to_return(status: 201, body: '{"id": "trace_123"}')

    stub_request(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
      .to_return(status: 201, body: '{"ingested": 1}')
  end

  describe ".start_trace" do
    it "starts a new trace" do
      trace = described_class.start_trace("user.request", kind: "request")

      expect(trace).not_to be_nil
      expect(trace[:name]).to eq("user.request")
      expect(trace[:kind]).to eq("request")
      expect(trace[:trace_id]).to be_a(String)
    end

    it "returns nil when pulse is disabled" do
      BrainzLab.configuration.pulse_enabled = false

      trace = described_class.start_trace("test")

      expect(trace).to be_nil
    end

    it "accepts custom attributes" do
      trace = described_class.start_trace("test", user_id: 123, custom: "value")

      expect(trace[:user_id]).to eq(123)
      expect(trace[:custom]).to eq("value")
    end

    it "accepts parent context for distributed tracing" do
      parent_ctx = BrainzLab::Pulse::Propagation::Context.new(
        trace_id: "parent-trace-id",
        span_id: "parent-span-id"
      )

      trace = described_class.start_trace("child", parent_context: parent_ctx)

      expect(trace[:parent_trace_id]).to eq("parent-trace-id")
      expect(trace[:parent_span_id]).to eq("parent-span-id")
    end
  end

  describe ".finish_trace" do
    it "finishes the current trace" do
      described_class.start_trace("test")
      described_class.finish_trace

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
    end

    it "records error information" do
      described_class.start_trace("test")
      described_class.finish_trace(
        error: true,
        error_class: "StandardError",
        error_message: "Something went wrong"
      )

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
        .with { |req|
          body = JSON.parse(req.body)
          body["error"] == true &&
            body["error_class"] == "StandardError" &&
            body["error_message"] == "Something went wrong"
        }
    end

    it "does nothing when pulse is disabled" do
      BrainzLab.configuration.pulse_enabled = false

      described_class.start_trace("test")
      described_class.finish_trace

      expect(WebMock).not_to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
    end
  end

  describe ".span" do
    it "executes block without trace" do
      result = described_class.span("test") { 42 }

      expect(result).to eq(42)
    end

    it "records span within trace" do
      described_class.start_trace("request")

      result = described_class.span("database", kind: "db") { 42 }

      expect(result).to eq(42)

      described_class.finish_trace

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
        .with { |req|
          body = JSON.parse(req.body)
          body["spans"].any? { |s| s["name"] == "database" && s["kind"] == "db" }
        }
    end

    it "measures span duration" do
      described_class.start_trace("request")

      described_class.span("slow_operation") do
        sleep 0.01
      end

      described_class.finish_trace

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
        .with { |req|
          body = JSON.parse(req.body)
          span = body["spans"].first
          span["duration_ms"].to_f > 0
        }
    end
  end

  describe ".record_trace" do
    it "records a complete trace" do
      started_at = Time.now - 2
      ended_at = Time.now

      described_class.record_trace(
        "background.job",
        kind: "job",
        started_at: started_at,
        ended_at: ended_at,
        status: 200
      )

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
        .with { |req|
          body = JSON.parse(req.body)
          body["name"] == "background.job" &&
            body["kind"] == "job" &&
            body["duration_ms"].to_f > 0
        }
    end

    it "does nothing when pulse is disabled" do
      BrainzLab.configuration.pulse_enabled = false

      described_class.record_trace("test", started_at: Time.now, ended_at: Time.now)

      expect(WebMock).not_to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/traces")
    end
  end

  describe ".record_metric" do
    it "records a custom metric" do
      described_class.record_metric("cpu.usage", value: 75.5, kind: "gauge", tags: { host: "web-01" })

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
        .with { |req|
          body = JSON.parse(req.body)
          body["name"] == "cpu.usage" &&
            body["value"] == 75.5 &&
            body["kind"] == "gauge" &&
            body["tags"]["host"] == "web-01"
        }
    end

    it "does nothing when pulse is disabled" do
      BrainzLab.configuration.pulse_enabled = false

      described_class.record_metric("test", value: 1)

      expect(WebMock).not_to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
    end
  end

  describe ".gauge" do
    it "records a gauge metric" do
      described_class.gauge("memory.used", 512, tags: { server: "app-01" })

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
        .with { |req|
          body = JSON.parse(req.body)
          body["name"] == "memory.used" &&
            body["value"] == 512 &&
            body["kind"] == "gauge"
        }
    end
  end

  describe ".counter" do
    it "records a counter metric" do
      described_class.counter("requests.total", 5, tags: { endpoint: "/api/users" })

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
        .with { |req|
          body = JSON.parse(req.body)
          body["name"] == "requests.total" &&
            body["value"] == 5 &&
            body["kind"] == "counter"
        }
    end

    it "defaults to incrementing by 1" do
      described_class.counter("page.views")

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
        .with { |req|
          body = JSON.parse(req.body)
          body["value"] == 1
        }
    end
  end

  describe ".histogram" do
    it "records a histogram metric" do
      described_class.histogram("response.time", 125.5, tags: { route: "users#index" })

      expect(WebMock).to have_requested(:post, "https://pulse.brainzlab.ai/api/v1/metrics")
        .with { |req|
          body = JSON.parse(req.body)
          body["name"] == "response.time" &&
            body["value"] == 125.5 &&
            body["kind"] == "histogram"
        }
    end
  end

  describe ".inject" do
    it "injects W3C trace context into headers" do
      described_class.start_trace("test")

      headers = {}
      described_class.inject(headers)

      expect(headers["traceparent"]).to match(/\A00-[a-f0-9]{32}-[a-f0-9]{16}-01\z/)
    end

    it "supports B3 format" do
      described_class.start_trace("test")

      headers = {}
      described_class.inject(headers, format: :b3)

      expect(headers["X-B3-TraceId"]).to be_a(String)
      expect(headers["X-B3-SpanId"]).to be_a(String)
      expect(headers["X-B3-Sampled"]).to eq("1")
    end

    it "supports all formats" do
      described_class.start_trace("test")

      headers = {}
      described_class.inject(headers, format: :all)

      expect(headers["traceparent"]).to be_a(String)
      expect(headers["X-B3-TraceId"]).to be_a(String)
    end
  end

  describe ".extract" do
    it "extracts W3C trace context from headers" do
      headers = {
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
      }

      context = described_class.extract(headers)

      expect(context).not_to be_nil
      expect(context.trace_id).to eq("0af7651916cd43dd8448eb211c80319c")
      expect(context.span_id).to eq("b7ad6b7169203331")
      expect(context.sampled).to be true
    end

    it "extracts B3 trace context from headers" do
      headers = {
        "X-B3-TraceId" => "0af7651916cd43dd8448eb211c80319c",
        "X-B3-SpanId" => "b7ad6b7169203331",
        "X-B3-Sampled" => "1"
      }

      context = described_class.extract(headers)

      expect(context).not_to be_nil
      expect(context.trace_id).to eq("0af7651916cd43dd8448eb211c80319c")
      expect(context.span_id).to eq("b7ad6b7169203331")
    end

    it "returns nil for invalid headers" do
      context = described_class.extract({})

      expect(context).to be_nil
    end
  end

  describe ".extract!" do
    it "extracts and sets current context" do
      headers = {
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
      }

      context = described_class.extract!(headers)

      expect(context).not_to be_nil
      expect(BrainzLab::Pulse::Propagation.current).to eq(context)
    end
  end

  describe ".reset!" do
    it "resets all pulse state" do
      described_class.start_trace("test")

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
      expect(described_class.instance_variable_get(:@tracer)).to be_nil
    end
  end
end
