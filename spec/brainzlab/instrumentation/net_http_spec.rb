# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "brainzlab/instrumentation/net_http"

RSpec.describe BrainzLab::Instrumentation::NetHttp do
  before do
    BrainzLab.configure do |c|
      c.secret_key = "test_key"
      c.instrument_http = true
      c.recall_enabled = true
      c.reflex_enabled = true
      c.http_ignore_hosts = %w[localhost 127.0.0.1]
    end

    # Stub Recall client to avoid actual HTTP calls
    stub_request(:post, %r{recall\.brainzlab\.ai/api/v1/logs?})
      .to_return(status: 200, body: "{}")
  end

  describe ".install!" do
    it "prepends the Patch module to Net::HTTP" do
      described_class.install!
      expect(described_class.installed?).to be true
    end

    it "is idempotent" do
      described_class.install!
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe "HTTP request tracking" do
    before do
      described_class.install!
    end

    context "successful requests" do
      it "adds a breadcrumb for GET requests" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 200, body: '{"users": []}')

        uri = URI("https://api.example.com/users")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb).not_to be_nil
        expect(http_crumb[:message]).to eq("GET https://api.example.com/users")
        expect(http_crumb[:level]).to eq("info")
        expect(http_crumb[:data][:status_code]).to eq(200)
        expect(http_crumb[:data][:duration_ms]).to be_a(Numeric)
      end

      it "adds a breadcrumb for POST requests" do
        stub_request(:post, "https://api.example.com/users")
          .to_return(status: 201, body: '{"id": 1}')

        uri = URI("https://api.example.com/users")
        Net::HTTP.post(uri, '{"name": "test"}', "Content-Type" => "application/json")

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb[:message]).to include("POST")
        expect(http_crumb[:data][:status_code]).to eq(201)
      end
    end

    context "error responses" do
      it "marks 4xx responses with error level" do
        stub_request(:get, "https://api.example.com/not-found")
          .to_return(status: 404, body: "Not Found")

        uri = URI("https://api.example.com/not-found")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb[:level]).to eq("error")
        expect(http_crumb[:data][:status_code]).to eq(404)
      end

      it "marks 5xx responses with error level" do
        stub_request(:get, "https://api.example.com/error")
          .to_return(status: 500, body: "Server Error")

        uri = URI("https://api.example.com/error")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb[:level]).to eq("error")
        expect(http_crumb[:data][:status_code]).to eq(500)
      end
    end

    context "connection errors" do
      it "tracks failed requests and re-raises the exception" do
        stub_request(:get, "https://api.example.com/timeout")
          .to_timeout

        uri = URI("https://api.example.com/timeout")

        expect {
          Net::HTTP.get(uri)
        }.to raise_error(Net::OpenTimeout)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb[:level]).to eq("error")
        expect(http_crumb[:data][:status_code]).to be_nil
        expect(http_crumb[:data][:error]).to eq("Net::OpenTimeout")
      end
    end

    context "ignored hosts" do
      it "does not track localhost requests" do
        stub_request(:get, "http://localhost:3000/health")
          .to_return(status: 200, body: "ok")

        uri = URI("http://localhost:3000/health")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb).to be_nil
      end

      it "does not track 127.0.0.1 requests" do
        stub_request(:get, "http://127.0.0.1:8080/health")
          .to_return(status: 200, body: "ok")

        uri = URI("http://127.0.0.1:8080/health")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb).to be_nil
      end

      it "respects custom ignore hosts" do
        BrainzLab.configuration.http_ignore_hosts = %w[internal.company.com]

        stub_request(:get, "https://internal.company.com/api")
          .to_return(status: 200, body: "ok")

        uri = URI("https://internal.company.com/api")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb).to be_nil
      end
    end

    context "configuration" do
      it "does not track when instrument_http is false" do
        BrainzLab.configuration.instrument_http = false

        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 200, body: "ok")

        uri = URI("https://api.example.com/users")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb).to be_nil
      end

      it "does not add breadcrumbs when reflex is disabled" do
        BrainzLab.configuration.reflex_enabled = false

        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 200, body: "ok")

        uri = URI("https://api.example.com/users")
        Net::HTTP.get(uri)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        http_crumb = crumbs.find { |c| c[:category] == "http" }

        expect(http_crumb).to be_nil
      end
    end
  end

  describe "URL building" do
    before do
      described_class.install!
    end

    it "includes non-standard ports" do
      stub_request(:get, "https://api.example.com:8443/users")
        .to_return(status: 200, body: "ok")

      uri = URI("https://api.example.com:8443/users")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.request(Net::HTTP::Get.new(uri))

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      http_crumb = crumbs.find { |c| c[:category] == "http" }

      expect(http_crumb[:message]).to include(":8443")
    end

    it "omits standard HTTPS port 443" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "ok")

      uri = URI("https://api.example.com/users")
      Net::HTTP.get(uri)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      http_crumb = crumbs.find { |c| c[:category] == "http" }

      expect(http_crumb[:message]).not_to include(":443")
    end

    it "omits standard HTTP port 80" do
      stub_request(:get, "http://api.example.com/users")
        .to_return(status: 200, body: "ok")

      uri = URI("http://api.example.com/users")
      Net::HTTP.get(uri)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      http_crumb = crumbs.find { |c| c[:category] == "http" }

      expect(http_crumb[:message]).not_to include(":80")
    end
  end
end
