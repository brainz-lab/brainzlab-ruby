# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Cortex do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.cortex_enabled = true
      config.cortex_cache_enabled = false
    end

    described_class.reset!

    stub_request(:post, "https://cortex.brainzlab.ai/api/v1/evaluate")
      .to_return(status: 200, body: '{"result": true}')

    stub_request(:post, "https://cortex.brainzlab.ai/api/v1/evaluate/batch")
      .to_return(status: 200, body: '{"flags": {"feature_x": true, "feature_y": false}}')

    stub_request(:get, "https://cortex.brainzlab.ai/api/v1/flags")
      .to_return(status: 200, body: '{"flags": [{"key": "feature_x", "enabled": true}]}')

    stub_request(:get, %r{cortex\.brainzlab\.ai/api/v1/flags/.*})
      .to_return(status: 200, body: '{"key": "feature_x", "enabled": true, "value": "variant_a"}')
  end

  describe ".enabled?" do
    it "checks if a feature flag is enabled" do
      result = described_class.enabled?("new_checkout")

      expect(result).to be true
      expect(WebMock).to have_requested(:post, "https://cortex.brainzlab.ai/api/v1/evaluate")
        .with { |req|
          body = JSON.parse(req.body)
          body["flag"] == "new_checkout"
        }
    end

    it "returns false when cortex is disabled" do
      BrainzLab.configuration.cortex_enabled = false

      result = described_class.enabled?("new_checkout")

      expect(result).to be false
      expect(WebMock).not_to have_requested(:post, %r{cortex\.brainzlab\.ai})
    end

    it "passes context to the API" do
      described_class.enabled?("new_checkout", user_id: 123, plan: "premium")

      expect(WebMock).to have_requested(:post, "https://cortex.brainzlab.ai/api/v1/evaluate")
        .with { |req|
          body = JSON.parse(req.body)
          body["context"]["user_id"] == 123 && body["context"]["plan"] == "premium"
        }
    end

    it "returns default value on API error" do
      stub_request(:post, "https://cortex.brainzlab.ai/api/v1/evaluate")
        .to_return(status: 500, body: '{"error": "Internal error"}')

      result = described_class.get("new_checkout", default: true)

      expect(result).to be true
    end
  end

  describe ".get" do
    it "gets a feature flag value" do
      stub_request(:post, "https://cortex.brainzlab.ai/api/v1/evaluate")
        .to_return(status: 200, body: '{"result": "variant_a"}')

      result = described_class.get("experiment_variant")

      expect(result).to eq("variant_a")
    end

    it "returns default when flag returns nil" do
      stub_request(:post, "https://cortex.brainzlab.ai/api/v1/evaluate")
        .to_return(status: 404, body: '{"error": "Not found"}')

      result = described_class.get("unknown_flag", default: "control")

      expect(result).to eq("control")
    end
  end

  describe ".list_flags" do
    it "lists all flags" do
      result = described_class.list_flags

      expect(result).to be_an(Array)
      expect(result.first[:key]).to eq("feature_x")
    end
  end

  describe ".all" do
    it "evaluates all flags at once" do
      result = described_class.all

      expect(result[:feature_x]).to be true
      expect(result[:feature_y]).to be false
    end

    it "passes context for evaluation" do
      described_class.all(user_id: 123)

      expect(WebMock).to have_requested(:post, "https://cortex.brainzlab.ai/api/v1/evaluate/batch")
        .with { |req|
          body = JSON.parse(req.body)
          body["context"]["user_id"] == 123
        }
    end
  end

  describe "caching" do
    before do
      BrainzLab.configuration.cortex_cache_enabled = true
      BrainzLab.configuration.cortex_cache_ttl = 60
      described_class.reset!
    end

    it "caches flag results" do
      described_class.enabled?("cached_flag")
      described_class.enabled?("cached_flag")

      expect(WebMock).to have_requested(:post, "https://cortex.brainzlab.ai/api/v1/evaluate").once
    end

    it "clears cache manually" do
      described_class.enabled?("cached_flag")
      described_class.clear_cache!
      described_class.enabled?("cached_flag")

      expect(WebMock).to have_requested(:post, "https://cortex.brainzlab.ai/api/v1/evaluate").twice
    end
  end

  describe ".reset!" do
    it "resets all cortex state" do
      described_class.enabled?("test")

      described_class.reset!

      expect(described_class.instance_variable_get(:@client)).to be_nil
      expect(described_class.instance_variable_get(:@cache)).to be_nil
    end
  end
end
