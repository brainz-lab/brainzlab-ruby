# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Configuration do
  let(:config) { described_class.new }

  describe "authentication keys" do
    describe "#reflex_auth_key" do
      it "returns reflex_api_key when set" do
        config.reflex_api_key = "reflex_key"
        config.secret_key = "secret"

        expect(config.reflex_auth_key).to eq("reflex_key")
      end

      it "falls back to secret_key" do
        config.secret_key = "secret"

        expect(config.reflex_auth_key).to eq("secret")
      end
    end

    describe "#pulse_auth_key" do
      it "returns pulse_api_key when set" do
        config.pulse_api_key = "pulse_key"
        config.secret_key = "secret"

        expect(config.pulse_auth_key).to eq("pulse_key")
      end

      it "falls back to secret_key" do
        config.secret_key = "secret"

        expect(config.pulse_auth_key).to eq("secret")
      end
    end

    describe "#flux_auth_key" do
      it "returns flux_ingest_key when set" do
        config.flux_ingest_key = "ingest_key"
        config.flux_api_key = "api_key"
        config.secret_key = "secret"

        expect(config.flux_auth_key).to eq("ingest_key")
      end

      it "returns flux_api_key when ingest_key not set" do
        config.flux_api_key = "api_key"
        config.secret_key = "secret"

        expect(config.flux_auth_key).to eq("api_key")
      end

      it "falls back to secret_key" do
        config.secret_key = "secret"

        expect(config.flux_auth_key).to eq("secret")
      end
    end

    describe "#signal_auth_key" do
      it "returns signal_api_key when set" do
        config.signal_api_key = "signal_key"
        config.secret_key = "secret"

        expect(config.signal_auth_key).to eq("signal_key")
      end

      it "falls back to secret_key" do
        config.secret_key = "secret"

        expect(config.signal_auth_key).to eq("secret")
      end
    end
  end

  describe "validation methods" do
    describe "#reflex_valid?" do
      it "returns true when reflex_api_key is set" do
        config.reflex_api_key = "key"

        expect(config.reflex_valid?).to be true
      end

      it "returns true when secret_key is set" do
        config.secret_key = "key"

        expect(config.reflex_valid?).to be true
      end

      it "returns false when both keys are empty" do
        config.reflex_api_key = ""
        config.secret_key = ""

        expect(config.reflex_valid?).to be false
      end

      it "returns false when both keys are nil" do
        expect(config.reflex_valid?).to be false
      end
    end

    describe "#pulse_valid?" do
      it "returns true when pulse_api_key is set" do
        config.pulse_api_key = "key"

        expect(config.pulse_valid?).to be true
      end

      it "returns true when secret_key is set" do
        config.secret_key = "key"

        expect(config.pulse_valid?).to be true
      end

      it "returns false when both keys are empty" do
        config.pulse_api_key = ""
        config.secret_key = ""

        expect(config.pulse_valid?).to be false
      end
    end

    describe "#flux_valid?" do
      it "returns true when flux_ingest_key is set" do
        config.flux_ingest_key = "key"

        expect(config.flux_valid?).to be true
      end

      it "returns true when flux_api_key is set" do
        config.flux_api_key = "key"

        expect(config.flux_valid?).to be true
      end

      it "returns true when secret_key is set" do
        config.secret_key = "key"

        expect(config.flux_valid?).to be true
      end

      it "returns false when all keys are empty" do
        config.flux_ingest_key = ""
        config.flux_api_key = ""
        config.secret_key = ""

        expect(config.flux_valid?).to be false
      end
    end

    describe "#signal_valid?" do
      it "returns true when signal_api_key is set" do
        config.signal_api_key = "key"

        expect(config.signal_valid?).to be true
      end

      it "returns true when secret_key is set" do
        config.secret_key = "key"

        expect(config.signal_valid?).to be true
      end

      it "returns false when both keys are empty" do
        config.signal_api_key = ""
        config.secret_key = ""

        expect(config.signal_valid?).to be false
      end
    end
  end

  describe "#recall_min_level=" do
    it "accepts string levels and converts to symbol" do
      config.recall_min_level = "error"

      expect(config.recall_min_level).to eq(:error)
    end
  end

  describe "#level_enabled?" do
    it "handles string level argument" do
      config.recall_min_level = :warn

      expect(config.level_enabled?("error")).to be true
      expect(config.level_enabled?("info")).to be false
    end
  end

  describe "environment detection" do
    it "detects Rails environment" do
      rails_env = double("env", to_s: "production")
      rails = double("Rails", env: rails_env, respond_to?: true)
      stub_const("Rails", rails)
      allow(rails).to receive(:respond_to?).with(:env).and_return(true)

      config = described_class.new

      expect(config.environment).to eq("production")
    end

    it "detects RACK_ENV" do
      stub_const("ENV", { "RACK_ENV" => "staging" })

      config = described_class.new

      expect(config.environment).to eq("staging")
    end

    it "detects RUBY_ENV" do
      stub_const("ENV", { "RUBY_ENV" => "test" })

      config = described_class.new

      expect(config.environment).to eq("test")
    end

    it "defaults to development" do
      # Ensure Rails is not defined and ENV vars are not set
      hide_const("Rails") if defined?(Rails)

      config = described_class.new

      expect(config.environment).to eq("development")
    end
  end

  describe "git context detection" do
    it "detects git commit from command" do
      allow_any_instance_of(described_class).to receive(:`).and_call_original
      allow_any_instance_of(described_class).to receive(:`).with("git rev-parse HEAD 2>/dev/null")
        .and_return("abc123def456\n")

      config = described_class.new

      expect(config.commit).to eq("abc123def456")
    end

    it "detects git branch from command" do
      allow_any_instance_of(described_class).to receive(:`).and_call_original
      allow_any_instance_of(described_class).to receive(:`).with("git rev-parse --abbrev-ref HEAD 2>/dev/null")
        .and_return("main\n")

      config = described_class.new

      expect(config.branch).to eq("main")
    end

    it "handles git command failure gracefully" do
      allow_any_instance_of(described_class).to receive(:`).and_call_original
      allow_any_instance_of(described_class).to receive(:`).with(/git rev-parse/).and_raise(StandardError)

      config = described_class.new

      expect(config.commit).to be_nil
      expect(config.branch).to be_nil
    end
  end

  describe "default values" do
    it "sets default buffer sizes" do
      expect(config.recall_buffer_size).to eq(50)
      expect(config.pulse_buffer_size).to eq(50)
      expect(config.flux_buffer_size).to eq(100)
    end

    it "sets default flush intervals" do
      expect(config.recall_flush_interval).to eq(5)
      expect(config.pulse_flush_interval).to eq(5)
      expect(config.flux_flush_interval).to eq(5)
    end

    it "sets default URLs" do
      expect(config.recall_url).to eq("https://recall.brainzlab.ai")
      expect(config.reflex_url).to eq("https://reflex.brainzlab.ai")
      expect(config.pulse_url).to eq("https://pulse.brainzlab.ai")
      expect(config.flux_url).to eq("https://flux.brainzlab.ai")
      expect(config.signal_url).to eq("https://signal.brainzlab.ai")
    end

    it "enables all services by default" do
      expect(config.recall_enabled).to be true
      expect(config.reflex_enabled).to be true
      expect(config.pulse_enabled).to be true
      expect(config.flux_enabled).to be true
      expect(config.signal_enabled).to be true
    end

    it "enables all instrumentation by default" do
      expect(config.instrument_http).to be true
      expect(config.instrument_active_record).to be true
      expect(config.instrument_redis).to be true
      expect(config.instrument_sidekiq).to be true
      expect(config.instrument_graphql).to be true
      expect(config.instrument_mongodb).to be true
      expect(config.instrument_elasticsearch).to be true
      expect(config.instrument_action_mailer).to be true
      expect(config.instrument_delayed_job).to be true
      expect(config.instrument_grape).to be true
    end

    it "sets default scrub fields" do
      expect(config.scrub_fields).to include(:password, :password_confirmation, :token, :api_key, :secret)
    end

    it "sets default http_ignore_hosts" do
      expect(config.http_ignore_hosts).to include("localhost", "127.0.0.1")
    end

    it "sets default redis_ignore_commands" do
      expect(config.redis_ignore_commands).to include("ping", "info")
    end

    it "sets default pulse_excluded_paths" do
      expect(config.pulse_excluded_paths).to include("/health", "/ping", "/up", "/assets")
    end

    it "enables auto-provisioning by default" do
      expect(config.recall_auto_provision).to be true
      expect(config.reflex_auto_provision).to be true
      expect(config.pulse_auto_provision).to be true
      expect(config.flux_auto_provision).to be true
      expect(config.signal_auto_provision).to be true
    end
  end

  describe "environment variable configuration" do
    it "reads secret_key from ENV" do
      stub_const("ENV", { "BRAINZLAB_SECRET_KEY" => "env_secret" })

      config = described_class.new

      expect(config.secret_key).to eq("env_secret")
    end

    it "reads service from ENV" do
      stub_const("ENV", { "BRAINZLAB_SERVICE" => "env_service" })

      config = described_class.new

      expect(config.service).to eq("env_service")
    end

    it "reads debug from ENV" do
      stub_const("ENV", { "BRAINZLAB_DEBUG" => "true" })

      config = described_class.new

      expect(config.debug).to be true
    end

    it "reads git context from ENV" do
      stub_const("ENV", { "GIT_COMMIT" => "commit123", "GIT_BRANCH" => "feature" })

      config = described_class.new

      expect(config.commit).to eq("commit123")
      expect(config.branch).to eq("feature")
    end
  end

  describe "log formatter settings" do
    it "sets default log formatter settings" do
      expect(config.log_formatter_enabled).to be true
      expect(config.log_formatter_colors).to be_nil
      expect(config.log_formatter_hide_assets).to be false
      expect(config.log_formatter_compact_assets).to be true
      expect(config.log_formatter_show_params).to be true
    end
  end
end
