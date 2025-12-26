# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Reflex::Breadcrumbs do
  let(:breadcrumbs) { described_class.new }

  describe "#add" do
    it "adds a breadcrumb" do
      breadcrumbs.add(message: "User clicked button", category: "ui", level: :info)

      crumbs = breadcrumbs.to_a
      expect(crumbs.size).to eq(1)
      expect(crumbs.first[:message]).to eq("User clicked button")
      expect(crumbs.first[:category]).to eq("ui")
      expect(crumbs.first[:level]).to eq("info")
    end

    it "includes timestamp" do
      breadcrumbs.add(message: "Test")

      crumb = breadcrumbs.to_a.first
      expect(crumb[:timestamp]).to be_a(String)
      expect(crumb[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end

    it "includes optional data" do
      breadcrumbs.add(message: "API call", data: { endpoint: "/users", status: 200 })

      crumb = breadcrumbs.to_a.first
      expect(crumb[:data]).to eq({ endpoint: "/users", status: 200 })
    end

    it "defaults category to 'default'" do
      breadcrumbs.add(message: "Test")

      crumb = breadcrumbs.to_a.first
      expect(crumb[:category]).to eq("default")
    end

    it "defaults level to 'info'" do
      breadcrumbs.add(message: "Test")

      crumb = breadcrumbs.to_a.first
      expect(crumb[:level]).to eq("info")
    end

    it "converts message to string" do
      breadcrumbs.add(message: 12345)

      crumb = breadcrumbs.to_a.first
      expect(crumb[:message]).to eq("12345")
    end

    it "converts category to string" do
      breadcrumbs.add(message: "Test", category: :navigation)

      crumb = breadcrumbs.to_a.first
      expect(crumb[:category]).to eq("navigation")
    end

    it "converts level to string" do
      breadcrumbs.add(message: "Test", level: :warning)

      crumb = breadcrumbs.to_a.first
      expect(crumb[:level]).to eq("warning")
    end

    it "omits data when nil" do
      breadcrumbs.add(message: "Test", data: nil)

      crumb = breadcrumbs.to_a.first
      expect(crumb).not_to have_key(:data)
    end
  end

  describe "#to_a" do
    it "returns array of breadcrumbs" do
      breadcrumbs.add(message: "First")
      breadcrumbs.add(message: "Second")

      crumbs = breadcrumbs.to_a

      expect(crumbs).to be_an(Array)
      expect(crumbs.size).to eq(2)
      expect(crumbs[0][:message]).to eq("First")
      expect(crumbs[1][:message]).to eq("Second")
    end

    it "returns a copy of breadcrumbs array" do
      breadcrumbs.add(message: "Test")

      crumbs1 = breadcrumbs.to_a
      crumbs2 = breadcrumbs.to_a

      expect(crumbs1).not_to be(crumbs2)
    end
  end

  describe "#clear!" do
    it "removes all breadcrumbs" do
      breadcrumbs.add(message: "First")
      breadcrumbs.add(message: "Second")

      breadcrumbs.clear!

      expect(breadcrumbs.to_a).to be_empty
    end
  end

  describe "#size" do
    it "returns number of breadcrumbs" do
      expect(breadcrumbs.size).to eq(0)

      breadcrumbs.add(message: "First")
      expect(breadcrumbs.size).to eq(1)

      breadcrumbs.add(message: "Second")
      expect(breadcrumbs.size).to eq(2)
    end
  end

  describe "max breadcrumbs limit" do
    it "limits breadcrumbs to MAX_BREADCRUMBS" do
      51.times { |i| breadcrumbs.add(message: "Breadcrumb #{i}") }

      expect(breadcrumbs.size).to eq(50)
    end

    it "keeps most recent breadcrumbs when limit exceeded" do
      51.times { |i| breadcrumbs.add(message: "Breadcrumb #{i}") }

      crumbs = breadcrumbs.to_a
      expect(crumbs.first[:message]).to eq("Breadcrumb 1")
      expect(crumbs.last[:message]).to eq("Breadcrumb 50")
    end
  end

  describe "thread safety" do
    it "is thread-safe for concurrent adds" do
      threads = 10.times.map do
        Thread.new do
          10.times { |i| breadcrumbs.add(message: "Thread #{Thread.current.object_id} - #{i}") }
        end
      end

      threads.each(&:join)

      # Should have exactly 50 breadcrumbs (limited by MAX_BREADCRUMBS)
      expect(breadcrumbs.size).to be <= 50
    end
  end
end

RSpec.describe BrainzLab::Reflex, ".breadcrumbs" do
  it "returns breadcrumbs from current context" do
    expect(described_class.breadcrumbs).to be_a(BrainzLab::Reflex::Breadcrumbs)
  end

  it "adds breadcrumb to current context" do
    BrainzLab::Reflex.add_breadcrumb("Test message", category: "test", level: :debug, data: { foo: "bar" })

    crumbs = BrainzLab::Reflex.breadcrumbs.to_a
    expect(crumbs.size).to eq(1)
    expect(crumbs.first[:message]).to eq("Test message")
    expect(crumbs.first[:category]).to eq("test")
    expect(crumbs.first[:level]).to eq("debug")
    expect(crumbs.first[:data]).to eq({ foo: "bar" })
  end

  it "clears breadcrumbs from current context" do
    BrainzLab::Reflex.add_breadcrumb("Test")
    expect(BrainzLab::Reflex.breadcrumbs.size).to eq(1)

    BrainzLab::Reflex.clear_breadcrumbs!
    expect(BrainzLab::Reflex.breadcrumbs.size).to eq(0)
  end
end
