# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab, ".health_check" do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.recall_enabled = true
      config.recall_url = "https://recall.brainzlab.ai"
      config.reflex_enabled = true
      config.reflex_url = "https://reflex.brainzlab.ai"
      config.pulse_enabled = true
      config.pulse_url = "https://pulse.brainzlab.ai"
      config.flux_enabled = true
      config.flux_url = "https://flux.brainzlab.ai"
      config.signal_enabled = true
      config.signal_url = "https://signal.brainzlab.ai"
    end
  end

  it "returns ok status when all services are healthy" do
    stub_request(:get, "https://recall.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://reflex.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://pulse.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://flux.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://signal.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")

    result = BrainzLab.health_check

    expect(result[:status]).to eq("ok")
    expect(result[:services]).to have_key(:recall)
    expect(result[:services]).to have_key(:reflex)
    expect(result[:services]).to have_key(:pulse)
    expect(result[:services]).to have_key(:flux)
    expect(result[:services]).to have_key(:signal)
    expect(result[:services][:recall][:status]).to eq("ok")
  end

  it "returns degraded status when a service is down" do
    stub_request(:get, "https://recall.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://reflex.brainzlab.ai/up")
      .to_return(status: 500, body: "Error")
    stub_request(:get, "https://pulse.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://flux.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://signal.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")

    result = BrainzLab.health_check

    expect(result[:status]).to eq("degraded")
    expect(result[:services][:reflex][:status]).to eq("error")
    expect(result[:services][:reflex][:message]).to include("500")
  end

  it "reports error when service times out" do
    stub_request(:get, "https://recall.brainzlab.ai/up")
      .to_timeout
    stub_request(:get, "https://reflex.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://pulse.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://flux.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://signal.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")

    result = BrainzLab.health_check

    expect(result[:services][:recall][:status]).to eq("error")
    expect(result[:services][:recall][:message]).to be_a(String)
  end

  it "reports error when service connection fails" do
    stub_request(:get, "https://recall.brainzlab.ai/up")
      .to_raise(SocketError.new("Failed to open TCP connection"))
    stub_request(:get, "https://reflex.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://pulse.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://flux.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://signal.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")

    result = BrainzLab.health_check

    expect(result[:services][:recall][:status]).to eq("error")
    expect(result[:services][:recall][:message]).to include("connection")
  end

  it "only checks enabled services" do
    BrainzLab.configuration.recall_enabled = false
    BrainzLab.configuration.pulse_enabled = false

    stub_request(:get, "https://reflex.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://flux.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://signal.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")

    result = BrainzLab.health_check

    expect(result[:services]).not_to have_key(:recall)
    expect(result[:services]).not_to have_key(:pulse)
    expect(result[:services]).to have_key(:reflex)
    expect(result[:services]).to have_key(:flux)
    expect(result[:services]).to have_key(:signal)
  end

  it "handles HTTPS URLs correctly" do
    BrainzLab.configuration.recall_url = "https://secure.brainzlab.ai"

    stub_request(:get, "https://secure.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://reflex.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://pulse.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://flux.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")
    stub_request(:get, "https://signal.brainzlab.ai/up")
      .to_return(status: 200, body: "OK")

    result = BrainzLab.health_check

    expect(result[:services][:recall][:status]).to eq("ok")
  end
end

RSpec.describe BrainzLab, ".logger" do
  it "creates a Recall logger" do
    logger = BrainzLab.logger

    expect(logger).to be_a(BrainzLab::Recall::Logger)
  end

  it "accepts broadcast_to option" do
    original_logger = Logger.new(STDOUT)
    logger = BrainzLab.logger(broadcast_to: original_logger)

    expect(logger.broadcast_to).to eq(original_logger)
  end
end

RSpec.describe BrainzLab, ".debug_log" do
  before do
    BrainzLab.configuration.debug = true
  end

  it "logs debug message when debug mode is enabled" do
    expect { BrainzLab.debug_log("Test debug message") }
      .to output(/Test debug message/).to_stderr
  end

  it "does nothing when debug mode is disabled" do
    BrainzLab.configuration.debug = false

    expect { BrainzLab.debug_log("Test debug message") }
      .not_to output.to_stderr
  end

  it "uses configured logger when available" do
    logger = double("logger")
    expect(logger).to receive(:debug).with("[BrainzLab::Debug] Test message")

    BrainzLab.configuration.logger = logger
    BrainzLab.debug_log("Test message")
  end
end

RSpec.describe BrainzLab, ".debug?" do
  it "returns true when debug mode is enabled" do
    BrainzLab.configuration.debug = true

    expect(BrainzLab.debug?).to be true
  end

  it "returns false when debug mode is disabled" do
    BrainzLab.configuration.debug = false

    expect(BrainzLab.debug?).to be false
  end
end

RSpec.describe BrainzLab, ".set_tags" do
  it "sets tags on current context" do
    BrainzLab.set_tags(environment: "production", version: "1.0")

    context = BrainzLab::Context.current
    expect(context.tags[:environment]).to eq("production")
    expect(context.tags[:version]).to eq("1.0")
  end
end

RSpec.describe BrainzLab, ".add_breadcrumb" do
  it "adds breadcrumb to current context" do
    BrainzLab.add_breadcrumb("User action", category: "ui", level: :info, data: { button: "submit" })

    crumbs = BrainzLab::Context.current.breadcrumbs.to_a
    expect(crumbs.size).to eq(1)
    expect(crumbs.first[:message]).to eq("User action")
    expect(crumbs.first[:category]).to eq("ui")
    expect(crumbs.first[:level]).to eq("info")
    expect(crumbs.first[:data]).to eq({ button: "submit" })
  end
end

RSpec.describe BrainzLab, ".clear_breadcrumbs!" do
  it "clears all breadcrumbs from current context" do
    BrainzLab.add_breadcrumb("Test 1")
    BrainzLab.add_breadcrumb("Test 2")

    expect(BrainzLab::Context.current.breadcrumbs.size).to eq(2)

    BrainzLab.clear_breadcrumbs!

    expect(BrainzLab::Context.current.breadcrumbs.size).to eq(0)
  end
end

RSpec.describe BrainzLab, ".reset_configuration!" do
  it "resets configuration to defaults" do
    BrainzLab.configure do |config|
      config.secret_key = "custom_key"
      config.service = "custom_service"
    end

    BrainzLab.reset_configuration!

    expect(BrainzLab.configuration.secret_key).to be_nil
    expect(BrainzLab.configuration.service).to be_nil
  end

  it "resets all module state" do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
    end

    # Trigger module initialization
    BrainzLab::Recall.instance_variable_set(:@client, "client")
    BrainzLab::Reflex.instance_variable_set(:@client, "client")
    BrainzLab::Pulse.instance_variable_set(:@client, "client")
    BrainzLab::Flux.instance_variable_set(:@client, "client")
    BrainzLab::Signal.instance_variable_set(:@client, "client")

    BrainzLab.reset_configuration!

    expect(BrainzLab::Recall.instance_variable_get(:@client)).to be_nil
    expect(BrainzLab::Reflex.instance_variable_get(:@client)).to be_nil
    expect(BrainzLab::Pulse.instance_variable_get(:@client)).to be_nil
    expect(BrainzLab::Flux.instance_variable_get(:@client)).to be_nil
    expect(BrainzLab::Signal.instance_variable_get(:@client)).to be_nil
  end
end
