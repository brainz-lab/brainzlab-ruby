# frozen_string_literal: true

module BrainzLab
  module Pulse
    class Tracer
      def initialize(config, client)
        @config = config
        @client = client
      end

      def current_trace
        Thread.current[:brainzlab_pulse_trace]
      end

      def current_spans
        Thread.current[:brainzlab_pulse_spans] ||= []
      end

      def start_trace(name, kind: "custom", **attributes)
        trace = {
          trace_id: SecureRandom.uuid,
          name: name,
          kind: kind,
          started_at: Time.now.utc,
          environment: @config.environment,
          commit: @config.commit,
          host: @config.host,
          **attributes
        }

        Thread.current[:brainzlab_pulse_trace] = trace
        Thread.current[:brainzlab_pulse_spans] = []

        trace
      end

      def finish_trace(error: false, error_class: nil, error_message: nil)
        trace = current_trace
        return unless trace

        ended_at = Time.now.utc
        duration_ms = ((ended_at - trace[:started_at]) * 1000).round(2)

        payload = trace.merge(
          ended_at: ended_at.iso8601(3),
          started_at: trace[:started_at].utc.iso8601(3),
          duration_ms: duration_ms,
          error: error,
          error_class: error_class,
          error_message: error_message,
          spans: current_spans.map { |s| format_span(s, trace[:started_at]) }
        ).compact

        # Add request context if available
        ctx = BrainzLab::Context.current
        payload[:request_id] ||= ctx.request_id
        payload[:user_id] ||= ctx.user&.dig(:id)&.to_s

        @client.send_trace(payload)

        Thread.current[:brainzlab_pulse_trace] = nil
        Thread.current[:brainzlab_pulse_spans] = nil

        payload
      end

      def span(name, kind: "custom", **data)
        span_data = {
          span_id: SecureRandom.uuid,
          name: name,
          kind: kind,
          started_at: Time.now.utc,
          data: data
        }

        begin
          result = yield
          span_data[:error] = false
          result
        rescue StandardError => e
          span_data[:error] = true
          span_data[:error_class] = e.class.name
          span_data[:error_message] = e.message
          raise
        ensure
          span_data[:ended_at] = Time.now.utc
          span_data[:duration_ms] = ((span_data[:ended_at] - span_data[:started_at]) * 1000).round(2)
          current_spans << span_data
        end
      end

      private

      def format_span(span, trace_started_at)
        {
          span_id: span[:span_id],
          parent_span_id: span[:parent_span_id],
          name: span[:name],
          kind: span[:kind],
          started_at: span[:started_at].utc.iso8601(3),
          ended_at: span[:ended_at].utc.iso8601(3),
          duration_ms: span[:duration_ms],
          error: span[:error],
          error_class: span[:error_class],
          error_message: span[:error_message],
          data: span[:data]
        }.compact
      end
    end
  end
end
