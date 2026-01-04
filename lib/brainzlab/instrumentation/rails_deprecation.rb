# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class RailsDeprecation
      class << self
        def install!
          return unless defined?(::Rails)
          return if @installed

          install_deprecation_subscriber!

          @installed = true
          BrainzLab.debug_log('Rails deprecation instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # deprecation.rails
        # Fired when a deprecated Rails API is used
        # ============================================
        def install_deprecation_subscriber!
          ActiveSupport::Notifications.subscribe('deprecation.rails') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_deprecation(event)
          end
        end

        def handle_deprecation(event)
          payload = event.payload

          message = payload[:message]
          callstack = payload[:callstack]
          gem_name = payload[:gem_name]
          deprecation_horizon = payload[:deprecation_horizon]

          # Extract relevant caller info
          caller_info = extract_caller_info(callstack)

          # Record breadcrumb with warning level
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Deprecation: #{truncate_message(message)}",
              category: 'rails.deprecation',
              level: :warning,
              data: {
                message: truncate_message(message, 500),
                gem_name: gem_name,
                deprecation_horizon: deprecation_horizon,
                caller: caller_info
              }.compact
            )
          end

          # Log to Recall for tracking
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Rails deprecation warning",
              message: truncate_message(message, 500),
              gem_name: gem_name,
              deprecation_horizon: deprecation_horizon,
              caller: caller_info,
              callstack: truncate_callstack(callstack)
            )
          end

          # Track deprecation count in Pulse metrics
          record_deprecation_metric(gem_name, deprecation_horizon)
        rescue StandardError => e
          BrainzLab.debug_log("Rails deprecation instrumentation failed: #{e.message}")
        end

        # ============================================
        # Helper Methods
        # ============================================
        def extract_caller_info(callstack)
          return nil unless callstack.is_a?(Array) && callstack.any?

          # Find the first non-Rails, non-gem caller
          app_caller = callstack.find do |line|
            line_str = line.to_s
            !line_str.include?('/gems/') &&
              !line_str.include?('/ruby/') &&
              !line_str.include?('/bundler/')
          end

          (app_caller || callstack.first).to_s
        end

        def truncate_callstack(callstack, max_lines = 5)
          return nil unless callstack.is_a?(Array)

          callstack.first(max_lines).map(&:to_s)
        end

        def truncate_message(message, max_length = 200)
          return 'unknown' unless message

          msg_str = message.to_s
          if msg_str.length > max_length
            "#{msg_str[0, max_length - 3]}..."
          else
            msg_str
          end
        end

        def record_deprecation_metric(gem_name, horizon)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          # If Pulse has a counter/metric API, use it here
          # For now, we just add a span to track it
          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'rails.deprecation',
            kind: 'internal',
            started_at: Time.now,
            ended_at: Time.now,
            duration_ms: 0,
            error: false,
            data: {
              'deprecation.gem_name' => gem_name,
              'deprecation.horizon' => horizon
            }.compact
          }

          tracer.current_spans << span_data
        end
      end
    end
  end
end
