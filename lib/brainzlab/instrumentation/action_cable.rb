# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActionCable
      # Thresholds for slow operations (in milliseconds)
      SLOW_ACTION_THRESHOLD = 100
      VERY_SLOW_ACTION_THRESHOLD = 500

      class << self
        def install!
          return unless defined?(::ActionCable)
          return if @installed

          install_perform_action_subscriber!
          install_transmit_subscriber!
          install_transmit_subscription_confirmation_subscriber!
          install_transmit_subscription_rejection_subscriber!
          install_broadcast_subscriber!

          @installed = true
          BrainzLab.debug_log('ActionCable instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # perform_action.action_cable
        # ============================================
        def install_perform_action_subscriber!
          ActiveSupport::Notifications.subscribe('perform_action.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_perform_action(event)
          end
        end

        def handle_perform_action(event)
          payload = event.payload
          duration = event.duration.round(2)

          channel_class = payload[:channel_class]
          action = payload[:action]
          data = payload[:data]

          # Determine level based on duration
          level = case duration
                  when 0...SLOW_ACTION_THRESHOLD then :info
                  when SLOW_ACTION_THRESHOLD...VERY_SLOW_ACTION_THRESHOLD then :warning
                  else :error
                  end

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cable action: #{channel_class}##{action} (#{duration}ms)",
              category: 'cable.action',
              level: level,
              data: {
                channel: channel_class,
                action: action,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_action_span(event, channel_class, action, duration, data)

          # Log slow actions
          log_slow_action(channel_class, action, duration) if duration >= SLOW_ACTION_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActionCable perform_action instrumentation failed: #{e.message}")
        end

        # ============================================
        # transmit.action_cable
        # ============================================
        def install_transmit_subscriber!
          ActiveSupport::Notifications.subscribe('transmit.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_transmit(event)
          end
        end

        def handle_transmit(event)
          payload = event.payload
          duration = event.duration.round(2)

          channel_class = payload[:channel_class]
          data = payload[:data]
          via = payload[:via]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            message = via ? "Cable transmit via #{via}" : 'Cable transmit'
            BrainzLab::Reflex.add_breadcrumb(
              "#{message}: #{channel_class} (#{duration}ms)",
              category: 'cable.transmit',
              level: :info,
              data: {
                channel: channel_class,
                via: via,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_transmit_span(event, channel_class, duration, via)
        rescue StandardError => e
          BrainzLab.debug_log("ActionCable transmit instrumentation failed: #{e.message}")
        end

        # ============================================
        # transmit_subscription_confirmation.action_cable
        # ============================================
        def install_transmit_subscription_confirmation_subscriber!
          ActiveSupport::Notifications.subscribe('transmit_subscription_confirmation.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_subscription_confirmation(event)
          end
        end

        def handle_subscription_confirmation(event)
          payload = event.payload
          duration = event.duration.round(2)

          channel_class = payload[:channel_class]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cable subscribed: #{channel_class}",
              category: 'cable.subscribe',
              level: :info,
              data: {
                channel: channel_class,
                status: 'confirmed',
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_subscription_span(event, channel_class, 'confirmed', duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActionCable subscription confirmation instrumentation failed: #{e.message}")
        end

        # ============================================
        # transmit_subscription_rejection.action_cable
        # ============================================
        def install_transmit_subscription_rejection_subscriber!
          ActiveSupport::Notifications.subscribe('transmit_subscription_rejection.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_subscription_rejection(event)
          end
        end

        def handle_subscription_rejection(event)
          payload = event.payload
          duration = event.duration.round(2)

          channel_class = payload[:channel_class]

          # Record breadcrumb - rejection is a warning
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cable subscription rejected: #{channel_class}",
              category: 'cable.subscribe',
              level: :warning,
              data: {
                channel: channel_class,
                status: 'rejected',
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_subscription_span(event, channel_class, 'rejected', duration)

          # Log rejection to Recall
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "ActionCable subscription rejected",
              channel: channel_class
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionCable subscription rejection instrumentation failed: #{e.message}")
        end

        # ============================================
        # broadcast.action_cable
        # ============================================
        def install_broadcast_subscriber!
          ActiveSupport::Notifications.subscribe('broadcast.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_broadcast(event)
          end
        end

        def handle_broadcast(event)
          payload = event.payload
          duration = event.duration.round(2)

          broadcasting = payload[:broadcasting]
          message = payload[:message]
          coder = payload[:coder]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cable broadcast: #{broadcasting} (#{duration}ms)",
              category: 'cable.broadcast',
              level: :info,
              data: {
                broadcasting: broadcasting,
                coder: coder&.to_s,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_broadcast_span(event, broadcasting, duration, coder)
        rescue StandardError => e
          BrainzLab.debug_log("ActionCable broadcast instrumentation failed: #{e.message}")
        end

        # ============================================
        # Span Recording Helpers
        # ============================================
        def record_action_span(event, channel_class, action, duration, data)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "cable.action.#{action}",
            kind: 'websocket',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'cable.channel' => channel_class,
              'cable.action' => action
            }.compact
          }

          tracer.current_spans << span_data
        end

        def record_transmit_span(event, channel_class, duration, via)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'cable.transmit',
            kind: 'websocket',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'cable.channel' => channel_class,
              'cable.via' => via
            }.compact
          }

          tracer.current_spans << span_data
        end

        def record_subscription_span(event, channel_class, status, duration)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'cable.subscribe',
            kind: 'websocket',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: status == 'rejected',
            data: {
              'cable.channel' => channel_class,
              'cable.subscription_status' => status
            }.compact
          }

          tracer.current_spans << span_data
        end

        def record_broadcast_span(event, broadcasting, duration, coder)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'cable.broadcast',
            kind: 'websocket',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'cable.broadcasting' => broadcasting,
              'cable.coder' => coder&.to_s
            }.compact
          }

          tracer.current_spans << span_data
        end

        # ============================================
        # Logging Helpers
        # ============================================
        def log_slow_action(channel_class, action, duration)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_ACTION_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow ActionCable action: #{channel_class}##{action} (#{duration}ms)",
            channel: channel_class,
            action: action,
            duration_ms: duration,
            threshold_exceeded: duration >= VERY_SLOW_ACTION_THRESHOLD ? 'critical' : 'warning'
          )
        end
      end
    end
  end
end
