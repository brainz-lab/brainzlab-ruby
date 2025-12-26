# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Pulse::Propagation do
  describe BrainzLab::Pulse::Propagation::Context do
    describe "#initialize" do
      it "generates trace_id and span_id by default" do
        context = described_class.new

        expect(context.trace_id).to be_a(String)
        expect(context.span_id).to be_a(String)
        expect(context.trace_id.length).to eq(32) # 16 bytes = 32 hex chars
        expect(context.span_id.length).to eq(16) # 8 bytes = 16 hex chars
      end

      it "accepts custom trace_id and span_id" do
        context = described_class.new(
          trace_id: "custom-trace-id",
          span_id: "custom-span-id"
        )

        expect(context.trace_id).to eq("custom-trace-id")
        expect(context.span_id).to eq("custom-span-id")
      end

      it "accepts parent_span_id" do
        context = described_class.new(parent_span_id: "parent-span")

        expect(context.parent_span_id).to eq("parent-span")
      end

      it "defaults sampled to true" do
        context = described_class.new

        expect(context.sampled).to be true
      end

      it "accepts custom sampled value" do
        context = described_class.new(sampled: false)

        expect(context.sampled).to be false
      end

      it "accepts tracestate" do
        context = described_class.new(tracestate: "vendor1=value1,vendor2=value2")

        expect(context.tracestate).to eq("vendor1=value1,vendor2=value2")
      end
    end

    describe "#valid?" do
      it "returns true when trace_id and span_id are present" do
        context = described_class.new

        expect(context).to be_valid
      end

      it "returns false when trace_id is missing" do
        context = described_class.new
        allow(context).to receive(:trace_id).and_return(nil)

        expect(context).not_to be_valid
      end

      it "returns false when span_id is missing" do
        context = described_class.new
        allow(context).to receive(:span_id).and_return(nil)

        expect(context).not_to be_valid
      end
    end

    describe "#to_h" do
      it "returns hash with all attributes" do
        context = described_class.new(
          trace_id: "trace-123",
          span_id: "span-456",
          parent_span_id: "parent-789",
          sampled: true,
          tracestate: "vendor=value"
        )

        hash = context.to_h

        expect(hash[:trace_id]).to eq("trace-123")
        expect(hash[:span_id]).to eq("span-456")
        expect(hash[:parent_span_id]).to eq("parent-789")
        expect(hash[:sampled]).to be true
        expect(hash[:tracestate]).to eq("vendor=value")
      end

      it "omits nil values" do
        context = described_class.new(
          trace_id: "trace-123",
          span_id: "span-456"
        )

        hash = context.to_h

        expect(hash).to have_key(:trace_id)
        expect(hash).to have_key(:span_id)
        expect(hash).not_to have_key(:parent_span_id)
        expect(hash).not_to have_key(:tracestate)
      end
    end
  end

  describe BrainzLab::Pulse::Propagation do
    before do
      described_class.clear!
    end

    describe ".current" do
      it "returns nil when no context is set" do
        expect(described_class.current).to be_nil
      end

      it "returns current context" do
        context = BrainzLab::Pulse::Propagation::Context.new
        described_class.current = context

        expect(described_class.current).to eq(context)
      end
    end

    describe ".current=" do
      it "sets current context" do
        context = BrainzLab::Pulse::Propagation::Context.new

        described_class.current = context

        expect(described_class.current).to eq(context)
      end
    end

    describe ".start" do
      it "creates and sets new context" do
        context = described_class.start

        expect(context).to be_a(BrainzLab::Pulse::Propagation::Context)
        expect(described_class.current).to eq(context)
      end

      it "accepts custom trace_id" do
        context = described_class.start(trace_id: "custom-trace")

        expect(context.trace_id).to eq("custom-trace")
      end

      it "accepts parent_span_id" do
        context = described_class.start(parent_span_id: "parent-span")

        expect(context.parent_span_id).to eq("parent-span")
      end
    end

    describe ".clear!" do
      it "clears current context" do
        described_class.start

        described_class.clear!

        expect(described_class.current).to be_nil
      end
    end

    describe ".inject (W3C format)" do
      it "injects traceparent header" do
        context = BrainzLab::Pulse::Propagation::Context.new(
          trace_id: "0af7651916cd43dd8448eb211c80319c",
          span_id: "b7ad6b7169203331",
          sampled: true
        )

        headers = {}
        described_class.inject(headers, context: context, format: :w3c)

        expect(headers["traceparent"]).to eq("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
      end

      it "injects tracestate header when present" do
        context = BrainzLab::Pulse::Propagation::Context.new(
          tracestate: "vendor1=value1"
        )

        headers = {}
        described_class.inject(headers, context: context, format: :w3c)

        expect(headers["tracestate"]).to eq("vendor1=value1")
      end

      it "sets sampled flag to 00 when not sampled" do
        context = BrainzLab::Pulse::Propagation::Context.new(sampled: false)

        headers = {}
        described_class.inject(headers, context: context, format: :w3c)

        expect(headers["traceparent"]).to end_with("-00")
      end

      it "normalizes trace_id to 32 characters" do
        context = BrainzLab::Pulse::Propagation::Context.new(trace_id: "abc123")

        headers = {}
        described_class.inject(headers, context: context, format: :w3c)

        expect(headers["traceparent"]).to match(/00-[a-f0-9]{32}-[a-f0-9]{16}-01/)
      end

      it "returns headers unchanged when context is nil" do
        headers = { "existing" => "header" }
        described_class.inject(headers, context: nil, format: :w3c)

        expect(headers).to eq({ "existing" => "header" })
      end

      it "returns headers unchanged when context is invalid" do
        context = BrainzLab::Pulse::Propagation::Context.new
        context.instance_variable_set(:@trace_id, nil)

        headers = { "existing" => "header" }
        described_class.inject(headers, context: context, format: :w3c)

        expect(headers).to eq({ "existing" => "header" })
      end
    end

    describe ".inject (B3 format)" do
      it "injects B3 headers" do
        context = BrainzLab::Pulse::Propagation::Context.new(
          trace_id: "0af7651916cd43dd8448eb211c80319c",
          span_id: "b7ad6b7169203331",
          sampled: true
        )

        headers = {}
        described_class.inject(headers, context: context, format: :b3)

        expect(headers["X-B3-TraceId"]).to eq("0af7651916cd43dd8448eb211c80319c")
        expect(headers["X-B3-SpanId"]).to eq("b7ad6b7169203331")
        expect(headers["X-B3-Sampled"]).to eq("1")
      end

      it "includes parent span ID when present" do
        context = BrainzLab::Pulse::Propagation::Context.new(
          parent_span_id: "parent-span-id"
        )

        headers = {}
        described_class.inject(headers, context: context, format: :b3)

        expect(headers["X-B3-ParentSpanId"]).to eq("parent-span-id")
      end

      it "sets sampled to 0 when not sampled" do
        context = BrainzLab::Pulse::Propagation::Context.new(sampled: false)

        headers = {}
        described_class.inject(headers, context: context, format: :b3)

        expect(headers["X-B3-Sampled"]).to eq("0")
      end
    end

    describe ".inject (all formats)" do
      it "injects both W3C and B3 headers" do
        context = BrainzLab::Pulse::Propagation::Context.new

        headers = {}
        described_class.inject(headers, context: context, format: :all)

        expect(headers["traceparent"]).to be_a(String)
        expect(headers["X-B3-TraceId"]).to be_a(String)
        expect(headers["X-B3-SpanId"]).to be_a(String)
      end
    end

    describe ".extract (W3C format)" do
      it "extracts context from traceparent header" do
        headers = {
          "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        }

        context = described_class.extract(headers)

        expect(context).to be_a(BrainzLab::Pulse::Propagation::Context)
        expect(context.trace_id).to eq("0af7651916cd43dd8448eb211c80319c")
        expect(context.span_id).to eq("b7ad6b7169203331")
        expect(context.sampled).to be true
      end

      it "extracts tracestate header" do
        headers = {
          "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
          "tracestate" => "vendor1=value1"
        }

        context = described_class.extract(headers)

        expect(context.tracestate).to eq("vendor1=value1")
      end

      it "handles HTTP_ prefix for Rack env" do
        headers = {
          "HTTP_TRACEPARENT" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        }

        context = described_class.extract(headers)

        expect(context).not_to be_nil
        expect(context.trace_id).to eq("0af7651916cd43dd8448eb211c80319c")
      end

      it "handles mixed case headers" do
        headers = {
          "Traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        }

        context = described_class.extract(headers)

        expect(context).not_to be_nil
      end

      it "extracts sampled flag correctly" do
        headers = {
          "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"
        }

        context = described_class.extract(headers)

        expect(context.sampled).to be false
      end

      it "returns nil for invalid version" do
        headers = {
          "traceparent" => "01-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end

      it "returns nil for invalid trace_id (wrong length)" do
        headers = {
          "traceparent" => "00-invalidtraceid-b7ad6b7169203331-01"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end

      it "returns nil for all-zero trace_id" do
        headers = {
          "traceparent" => "00-00000000000000000000000000000000-b7ad6b7169203331-01"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end

      it "returns nil for invalid span_id (wrong length)" do
        headers = {
          "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-invalidspan-01"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end

      it "returns nil for all-zero span_id" do
        headers = {
          "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end
    end

    describe ".extract (B3 format)" do
      it "extracts context from B3 headers" do
        headers = {
          "X-B3-TraceId" => "0af7651916cd43dd8448eb211c80319c",
          "X-B3-SpanId" => "b7ad6b7169203331",
          "X-B3-Sampled" => "1"
        }

        context = described_class.extract(headers)

        expect(context).to be_a(BrainzLab::Pulse::Propagation::Context)
        expect(context.trace_id).to eq("0af7651916cd43dd8448eb211c80319c")
        expect(context.span_id).to eq("b7ad6b7169203331")
        expect(context.sampled).to be true
      end

      it "handles HTTP_ prefix for B3 headers" do
        headers = {
          "HTTP_X_B3_TRACEID" => "0af7651916cd43dd8448eb211c80319c",
          "HTTP_X_B3_SPANID" => "b7ad6b7169203331"
        }

        context = described_class.extract(headers)

        expect(context).not_to be_nil
      end

      it "handles lowercase B3 headers" do
        headers = {
          "x-b3-traceid" => "0af7651916cd43dd8448eb211c80319c",
          "x-b3-spanid" => "b7ad6b7169203331"
        }

        context = described_class.extract(headers)

        expect(context).not_to be_nil
      end

      it "extracts parent span ID" do
        headers = {
          "X-B3-TraceId" => "0af7651916cd43dd8448eb211c80319c",
          "X-B3-SpanId" => "b7ad6b7169203331",
          "X-B3-ParentSpanId" => "parent-span-id"
        }

        context = described_class.extract(headers)

        expect(context.parent_span_id).to eq("parent-span-id")
      end

      it "defaults sampled to true when header missing" do
        headers = {
          "X-B3-TraceId" => "0af7651916cd43dd8448eb211c80319c",
          "X-B3-SpanId" => "b7ad6b7169203331"
        }

        context = described_class.extract(headers)

        expect(context.sampled).to be true
      end

      it "sets sampled to false when header is 0" do
        headers = {
          "X-B3-TraceId" => "0af7651916cd43dd8448eb211c80319c",
          "X-B3-SpanId" => "b7ad6b7169203331",
          "X-B3-Sampled" => "0"
        }

        context = described_class.extract(headers)

        expect(context.sampled).to be false
      end

      it "returns nil when trace_id is missing" do
        headers = {
          "X-B3-SpanId" => "b7ad6b7169203331"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end

      it "returns nil when span_id is missing" do
        headers = {
          "X-B3-TraceId" => "0af7651916cd43dd8448eb211c80319c"
        }

        context = described_class.extract(headers)

        expect(context).to be_nil
      end
    end

    describe ".extract (fallback)" do
      it "tries W3C format first, then B3" do
        headers = {
          "X-B3-TraceId" => "b3-trace-id",
          "X-B3-SpanId" => "b3-span-id"
        }

        context = described_class.extract(headers)

        expect(context.trace_id).to eq("b3-trace-id")
      end

      it "returns nil when no valid headers present" do
        headers = { "Other-Header" => "value" }

        context = described_class.extract(headers)

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
        expect(described_class.current).to eq(context)
      end

      it "sets current to nil when extraction fails" do
        headers = {}

        context = described_class.extract!(headers)

        expect(context).to be_nil
        expect(described_class.current).to be_nil
      end
    end

    describe ".child_context" do
      it "creates child context with same trace_id" do
        parent = BrainzLab::Pulse::Propagation::Context.new(
          trace_id: "parent-trace-id",
          span_id: "parent-span-id"
        )

        child = described_class.child_context(parent: parent)

        expect(child.trace_id).to eq("parent-trace-id")
        expect(child.parent_span_id).to eq("parent-span-id")
        expect(child.span_id).not_to eq("parent-span-id")
      end

      it "uses current context as parent by default" do
        described_class.start(trace_id: "current-trace-id")

        child = described_class.child_context

        expect(child.trace_id).to eq("current-trace-id")
      end

      it "inherits sampled flag" do
        parent = BrainzLab::Pulse::Propagation::Context.new(sampled: false)

        child = described_class.child_context(parent: parent)

        expect(child.sampled).to be false
      end

      it "inherits tracestate" do
        parent = BrainzLab::Pulse::Propagation::Context.new(tracestate: "vendor=value")

        child = described_class.child_context(parent: parent)

        expect(child.tracestate).to eq("vendor=value")
      end

      it "creates new context when parent is nil" do
        child = described_class.child_context(parent: nil)

        expect(child).to be_a(BrainzLab::Pulse::Propagation::Context)
        expect(child.parent_span_id).to be_nil
      end

      it "creates new context when parent is invalid" do
        parent = BrainzLab::Pulse::Propagation::Context.new
        parent.instance_variable_set(:@trace_id, nil)

        child = described_class.child_context(parent: parent)

        expect(child.parent_span_id).to be_nil
      end
    end
  end
end
