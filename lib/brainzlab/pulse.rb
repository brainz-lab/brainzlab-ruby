# frozen_string_literal: true

require_relative "pulse/client"
require_relative "pulse/provisioner"
require_relative "pulse/tracer"
require_relative "pulse/instrumentation"
require_relative "pulse/propagation"

module BrainzLab
  module Pulse
    class << self
      # Start a new trace
      # @param name [String] the trace name
      # @param kind [String] trace kind (request, job, custom)
      # @param parent_context [Propagation::Context] optional parent context for distributed tracing
      def start_trace(name, kind: "custom", parent_context: nil, **attributes)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.pulse_valid?

        # Use parent context trace_id if provided (distributed tracing)
        if parent_context&.valid?
          attributes[:parent_trace_id] = parent_context.trace_id
          attributes[:parent_span_id] = parent_context.span_id
        end

        tracer.start_trace(name, kind: kind, **attributes)
      end

      # Finish current trace
      def finish_trace(error: false, error_class: nil, error_message: nil)
        return unless enabled?

        tracer.finish_trace(error: error, error_class: error_class, error_message: error_message)
      end

      # Add a span to the current trace
      def span(name, kind: "custom", **data)
        return yield unless enabled?
        return yield unless tracer.current_trace

        tracer.span(name, kind: kind, **data) { yield }
      end

      # Record a complete trace (for when you have all data upfront)
      def record_trace(name, kind: "request", started_at:, ended_at:, **attributes)
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.pulse_valid?

        payload = build_trace_payload(name, kind, started_at, ended_at, attributes)
        client.send_trace(payload)
      end

      # Record a custom metric
      def record_metric(name, value:, kind: "gauge", tags: {})
        return unless enabled?

        ensure_provisioned!
        return unless BrainzLab.configuration.pulse_valid?

        payload = {
          name: name,
          value: value,
          kind: kind,
          timestamp: Time.now.utc.iso8601(3),
          tags: tags
        }

        client.send_metric(payload)
      end

      # Convenience methods for metrics
      def gauge(name, value, tags: {})
        record_metric(name, value: value, kind: "gauge", tags: tags)
      end

      def counter(name, value = 1, tags: {})
        record_metric(name, value: value, kind: "counter", tags: tags)
      end

      def histogram(name, value, tags: {})
        record_metric(name, value: value, kind: "histogram", tags: tags)
      end

      def ensure_provisioned!
        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      def tracer
        @tracer ||= Tracer.new(BrainzLab.configuration, client)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def reset!
        @client = nil
        @tracer = nil
        @provisioner = nil
        @provisioned = false
        Propagation.clear!
      end

      # Distributed tracing: inject trace context into outgoing headers
      # @param headers [Hash] the headers hash to inject into
      # @param format [Symbol] :w3c (default), :b3, or :all
      # @return [Hash] the headers with trace context added
      def inject(headers, format: :w3c)
        ctx = Propagation.current || create_propagation_context
        Propagation.inject(headers, context: ctx, format: format)
      end

      # Distributed tracing: extract trace context from incoming headers
      # @param headers [Hash] incoming headers (Rack env or plain headers)
      # @return [Propagation::Context, nil] extracted context
      def extract(headers)
        Propagation.extract(headers)
      end

      # Distributed tracing: extract and set as current context
      # @param headers [Hash] incoming headers
      # @return [Propagation::Context, nil] extracted context
      def extract!(headers)
        Propagation.extract!(headers)
      end

      # Get current propagation context
      def propagation_context
        Propagation.current
      end

      # Create a child propagation context for a new span
      def child_context
        Propagation.child_context
      end

      private

      def create_propagation_context
        trace = tracer.current_trace
        if trace
          Propagation::Context.new(
            trace_id: trace[:trace_id],
            span_id: SecureRandom.hex(8)
          )
        else
          Propagation::Context.new
        end
      end

      def enabled?
        BrainzLab.configuration.pulse_enabled
      end

      def build_trace_payload(name, kind, started_at, ended_at, attributes)
        config = BrainzLab.configuration
        ctx = Context.current

        duration_ms = ((ended_at - started_at) * 1000).round(2)

        {
          trace_id: attributes[:trace_id] || SecureRandom.uuid,
          name: name,
          kind: kind,
          started_at: started_at.utc.iso8601(3),
          ended_at: ended_at.utc.iso8601(3),
          duration_ms: duration_ms,

          # Distributed tracing - parent trace info
          parent_trace_id: attributes[:parent_trace_id],
          parent_span_id: attributes[:parent_span_id],

          # Environment
          environment: config.environment,
          commit: config.commit,
          host: config.host,

          # Request context
          request_id: ctx.request_id || attributes[:request_id],
          request_method: attributes[:request_method],
          request_path: attributes[:request_path],
          controller: attributes[:controller],
          action: attributes[:action],
          status: attributes[:status],

          # Timing breakdown
          view_ms: attributes[:view_ms],
          db_ms: attributes[:db_ms],
          external_ms: attributes[:external_ms],
          cache_ms: attributes[:cache_ms],

          # Job context
          job_class: attributes[:job_class],
          job_id: attributes[:job_id],
          queue: attributes[:queue],
          queue_wait_ms: attributes[:queue_wait_ms],
          executions: attributes[:executions],

          # User
          user_id: ctx.user&.dig(:id)&.to_s || attributes[:user_id],

          # Error info
          error: attributes[:error] || false,
          error_class: attributes[:error_class],
          error_message: attributes[:error_message],

          # Spans
          spans: attributes[:spans] || []
        }.compact
      end
    end
  end
end
