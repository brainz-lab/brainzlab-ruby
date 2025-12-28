# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Flux do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.flux_enabled = true
      config.flux_ingest_key = "test_flux_key"  # Set to skip auto-provisioning
    end

    described_class.reset!

    stub_request(:post, %r{flux\.brainzlab\.ai/api/v1/(events|metrics|flux/batch)})
      .to_return(status: 201, body: '{"ingested": 1}')
  end

  describe ".track" do
    it "tracks a custom event" do
      described_class.track("user.signup", email: "test@example.com", plan: "premium")
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          events = body["events"]
          events.any? { |e|
            e["name"] == "user.signup" &&
              e["properties"]["email"] == "test@example.com" &&
              e["properties"]["plan"] == "premium"
          }
        }
    end

    it "separates special properties from event properties" do
      described_class.track(
        "purchase.completed",
        user_id: "user-123",
        value: 99.99,
        tags: { source: "web" },
        session_id: "sess-456",
        item: "widget"
      )
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          event = body["events"].first
          event["user_id"] == "user-123" &&
            event["value"] == 99.99 &&
            event["tags"]["source"] == "web" &&
            event["session_id"] == "sess-456" &&
            event["properties"]["item"] == "widget" &&
            event["properties"]["user_id"].nil?
        }
    end

    it "includes environment and service" do
      described_class.track("test.event")
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          event = body["events"].first
          event["environment"] == "test" &&
            event["service"] == "test-service"
        }
    end

    it "does nothing when flux is disabled" do
      BrainzLab.configuration.flux_enabled = false

      described_class.track("test.event")
      described_class.flush!

      expect(WebMock).not_to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
    end
  end

  describe ".track_for_user" do
    it "tracks event with user ID from object" do
      user = double(id: 123)

      described_class.track_for_user(user, "profile.updated", changes: 5)
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          event = body["events"].first
          event["name"] == "profile.updated" &&
            event["user_id"] == "123"
        }
    end

    it "tracks event with user ID from string" do
      described_class.track_for_user("user-456", "login")
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          event = body["events"].first
          event["user_id"] == "user-456"
        }
    end
  end

  describe ".gauge" do
    it "records a gauge metric" do
      described_class.gauge("cpu.usage", 75.5, tags: { host: "web-01" })
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metrics = body["metrics"]
          metrics.any? { |m|
            m["type"] == "gauge" &&
              m["name"] == "cpu.usage" &&
              m["value"] == 75.5 &&
              m["tags"]["host"] == "web-01"
          }
        }
    end

    it "does nothing when flux is disabled" do
      BrainzLab.configuration.flux_enabled = false

      described_class.gauge("test.metric", 100)
      described_class.flush!

      expect(WebMock).not_to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
    end
  end

  describe ".increment" do
    it "increments a counter by specified value" do
      described_class.increment("requests.total", 5, tags: { endpoint: "/api/users" })
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["type"] == "counter" &&
            metric["name"] == "requests.total" &&
            metric["value"] == 5
        }
    end

    it "defaults to incrementing by 1" do
      described_class.increment("page.views")
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["value"] == 1
        }
    end
  end

  describe ".decrement" do
    it "decrements a counter" do
      described_class.decrement("connections.active", 3)
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["type"] == "counter" &&
            metric["value"] == -3
        }
    end

    it "defaults to decrementing by 1" do
      described_class.decrement("queue.size")
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["value"] == -1
        }
    end
  end

  describe ".distribution" do
    it "records a distribution metric" do
      described_class.distribution("response.time", 125.5, tags: { route: "users#index" })
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["type"] == "distribution" &&
            metric["name"] == "response.time" &&
            metric["value"] == 125.5
        }
    end
  end

  describe ".set" do
    it "records a set metric" do
      described_class.set("unique.users", "user-123", tags: { page: "home" })
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["type"] == "set" &&
            metric["name"] == "unique.users" &&
            metric["value"] == "user-123"
        }
    end

    it "converts value to string" do
      described_class.set("active.sessions", 12345)
      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["value"] == "12345"
        }
    end
  end

  describe ".measure" do
    it "measures block duration and records as distribution" do
      result = described_class.measure("database.query", tags: { table: "users" }) do
        sleep 0.01
        42
      end

      described_class.flush!

      expect(result).to eq(42)
      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["type"] == "distribution" &&
            metric["name"] == "database.query" &&
            metric["value"].to_f > 0 &&
            metric["tags"]["unit"] == "ms"
        }
    end

    it "records duration even when block raises error" do
      expect {
        described_class.measure("failing.operation") do
          sleep 0.01
          raise StandardError, "Test error"
        end
      }.to raise_error(StandardError)

      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
        .with { |req|
          body = JSON.parse(req.body)
          metric = body["metrics"].first
          metric["name"] == "failing.operation" &&
            metric["value"].to_f > 0
        }
    end
  end

  describe ".flush!" do
    it "immediately flushes buffered data" do
      described_class.track("test.event")

      expect(WebMock).not_to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")

      described_class.flush!

      expect(WebMock).to have_requested(:post, "https://flux.brainzlab.ai/api/v1/flux/batch")
    end
  end

  describe ".reset!" do
    it "resets all flux state" do
      described_class.track("test.event")

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
      expect(described_class.instance_variable_get(:@buffer)).to be_nil
    end
  end
end
