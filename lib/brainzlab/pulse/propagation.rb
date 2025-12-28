# frozen_string_literal: true

module BrainzLab
  module Pulse
    # Distributed tracing context propagation using W3C Trace Context format
    # https://www.w3.org/TR/trace-context/
    module Propagation
      # W3C Trace Context header names
      TRACEPARENT_HEADER = "traceparent"
      TRACESTATE_HEADER = "tracestate"

      # HTTP header versions (with HTTP_ prefix for Rack env)
      HTTP_TRACEPARENT = "HTTP_TRACEPARENT"
      HTTP_TRACESTATE = "HTTP_TRACESTATE"

      # Also support B3 format for compatibility
      B3_TRACE_ID = "X-B3-TraceId"
      B3_SPAN_ID = "X-B3-SpanId"
      B3_SAMPLED = "X-B3-Sampled"
      B3_PARENT_SPAN_ID = "X-B3-ParentSpanId"

      class Context
        attr_accessor :trace_id, :span_id, :parent_span_id, :sampled, :tracestate

        def initialize(trace_id: nil, span_id: nil, parent_span_id: nil, sampled: true, tracestate: nil)
          @trace_id = trace_id || generate_trace_id
          @span_id = span_id || generate_span_id
          @parent_span_id = parent_span_id
          @sampled = sampled
          @tracestate = tracestate
        end

        def valid?
          !trace_id.nil? && !span_id.nil?
        end

        def to_h
          {
            trace_id: @trace_id,
            span_id: @span_id,
            parent_span_id: @parent_span_id,
            sampled: @sampled,
            tracestate: @tracestate
          }.compact
        end

        private

        def generate_trace_id
          SecureRandom.hex(16) # 32 hex chars = 128 bits
        end

        def generate_span_id
          SecureRandom.hex(8) # 16 hex chars = 64 bits
        end
      end

      class << self
        # Get current propagation context from thread local
        def current
          Thread.current[:brainzlab_propagation_context]
        end

        # Set current propagation context
        def current=(context)
          Thread.current[:brainzlab_propagation_context] = context
        end

        # Create new context and set as current
        def start(trace_id: nil, parent_span_id: nil)
          self.current = Context.new(
            trace_id: trace_id,
            parent_span_id: parent_span_id
          )
        end

        # Clear current context
        def clear!
          Thread.current[:brainzlab_propagation_context] = nil
        end

        # Inject trace context into outgoing HTTP headers
        # @param headers [Hash] the headers hash to inject into
        # @param context [Context] optional context (defaults to current)
        # @param format [Symbol] :w3c (default), :b3, or :all
        def inject(headers, context: nil, format: :w3c)
          ctx = context || current
          return headers unless ctx&.valid?

          case format
          when :w3c
            inject_w3c(headers, ctx)
          when :b3
            inject_b3(headers, ctx)
          when :all
            inject_w3c(headers, ctx)
            inject_b3(headers, ctx)
          end

          headers
        end

        # Extract trace context from incoming HTTP headers (Rack env or plain headers)
        # @param headers [Hash] the headers to extract from
        # @return [Context, nil] the extracted context or nil
        def extract(headers)
          # Try W3C format first
          ctx = extract_w3c(headers)
          return ctx if ctx

          # Fall back to B3 format
          extract_b3(headers)
        end

        # Extract and set as current context
        # Returns the context for chaining
        def extract!(headers)
          self.current = extract(headers)
        end

        # Create a child context for a new span
        def child_context(parent: nil)
          parent ||= current
          return Context.new unless parent&.valid?

          Context.new(
            trace_id: parent.trace_id,
            parent_span_id: parent.span_id,
            sampled: parent.sampled,
            tracestate: parent.tracestate
          )
        end

        private

        # W3C Trace Context format injection
        # traceparent: version-traceid-spanid-flags
        # Example: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
        def inject_w3c(headers, ctx)
          version = "00"
          flags = ctx.sampled ? "01" : "00"
          trace_id = normalize_trace_id(ctx.trace_id, 32)
          span_id = normalize_trace_id(ctx.span_id, 16)

          headers[TRACEPARENT_HEADER] = "#{version}-#{trace_id}-#{span_id}-#{flags}"
          headers[TRACESTATE_HEADER] = ctx.tracestate if ctx.tracestate

          headers
        end

        # W3C Trace Context format extraction
        def extract_w3c(headers)
          traceparent = headers[TRACEPARENT_HEADER] ||
                        headers[HTTP_TRACEPARENT] ||
                        headers["Traceparent"]
          return nil unless traceparent

          # Parse: version-traceid-spanid-flags
          parts = traceparent.to_s.split("-")
          return nil if parts.length < 4

          version, trace_id, span_id, flags = parts

          # Validate version
          return nil unless version == "00"

          # Validate trace_id (32 hex chars, not all zeros)
          return nil unless trace_id&.match?(/\A[a-f0-9]{32}\z/i)
          return nil if trace_id == "0" * 32

          # Validate span_id (16 hex chars, not all zeros)
          return nil unless span_id&.match?(/\A[a-f0-9]{16}\z/i)
          return nil if span_id == "0" * 16

          sampled = flags.to_i(16) & 0x01 == 1

          tracestate = headers[TRACESTATE_HEADER] ||
                       headers[HTTP_TRACESTATE] ||
                       headers["Tracestate"]

          Context.new(
            trace_id: trace_id,
            span_id: span_id,
            sampled: sampled,
            tracestate: tracestate
          )
        rescue StandardError
          nil
        end

        # B3 format injection (Zipkin compatibility)
        def inject_b3(headers, ctx)
          headers[B3_TRACE_ID] = normalize_trace_id(ctx.trace_id, 32)
          headers[B3_SPAN_ID] = normalize_trace_id(ctx.span_id, 16)
          headers[B3_SAMPLED] = ctx.sampled ? "1" : "0"
          headers[B3_PARENT_SPAN_ID] = ctx.parent_span_id if ctx.parent_span_id

          headers
        end

        # B3 format extraction
        def extract_b3(headers)
          trace_id = headers[B3_TRACE_ID] ||
                     headers["HTTP_X_B3_TRACEID"] ||
                     headers["x-b3-traceid"]
          return nil unless trace_id

          span_id = headers[B3_SPAN_ID] ||
                    headers["HTTP_X_B3_SPANID"] ||
                    headers["x-b3-spanid"]
          return nil unless span_id

          sampled_header = headers[B3_SAMPLED] ||
                           headers["HTTP_X_B3_SAMPLED"] ||
                           headers["x-b3-sampled"]
          sampled = sampled_header != "0"

          parent_span_id = headers[B3_PARENT_SPAN_ID] ||
                           headers["HTTP_X_B3_PARENTSPANID"] ||
                           headers["x-b3-parentspanid"]

          Context.new(
            trace_id: trace_id,
            span_id: span_id,
            parent_span_id: parent_span_id,
            sampled: sampled
          )
        rescue StandardError
          nil
        end

        def normalize_trace_id(id, length)
          return nil unless id

          hex = id.to_s.gsub("-", "").downcase
          hex.rjust(length, "0").slice(0, length)
        end
      end
    end
  end
end
