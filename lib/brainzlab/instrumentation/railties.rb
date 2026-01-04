# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class Railties
      # Thresholds for slow initializers (in milliseconds)
      SLOW_INITIALIZER_THRESHOLD = 100   # 100ms
      VERY_SLOW_INITIALIZER_THRESHOLD = 500  # 500ms

      class << self
        def install!
          return unless defined?(::Rails)
          return if @installed

          install_load_config_initializer_subscriber!

          @installed = true
          BrainzLab.debug_log('Railties instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # load_config_initializer.railties
        # Fired when each config initializer is loaded
        # ============================================
        def install_load_config_initializer_subscriber!
          ActiveSupport::Notifications.subscribe('load_config_initializer.railties') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_load_config_initializer(event)
          end
        end

        def handle_load_config_initializer(event)
          payload = event.payload
          duration = event.duration.round(2)

          initializer = payload[:initializer]

          # Extract just the filename for cleaner display
          initializer_name = extract_initializer_name(initializer)

          # Determine level based on duration
          level = case duration
                  when 0...SLOW_INITIALIZER_THRESHOLD then :info
                  when SLOW_INITIALIZER_THRESHOLD...VERY_SLOW_INITIALIZER_THRESHOLD then :warning
                  else :error
                  end

          # Record breadcrumb (only for slow initializers to reduce noise during boot)
          if duration >= 10 && BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Initializer loaded: #{initializer_name} (#{duration}ms)",
              category: 'rails.initializer',
              level: level,
              data: {
                initializer: initializer_name,
                path: initializer,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span for tracking boot time
          record_initializer_span(event, initializer_name, initializer, duration)

          # Log slow initializers
          log_slow_initializer(initializer_name, initializer, duration) if duration >= SLOW_INITIALIZER_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("Railties load_config_initializer instrumentation failed: #{e.message}")
        end

        # ============================================
        # Span Recording
        # ============================================
        def record_initializer_span(event, name, path, duration)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "rails.initializer.#{name}",
            kind: 'internal',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'rails.initializer.name' => name,
              'rails.initializer.path' => path
            }.compact
          }

          tracer.current_spans << span_data
        end

        # ============================================
        # Logging
        # ============================================
        def log_slow_initializer(name, path, duration)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_INITIALIZER_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow initializer: #{name} (#{duration}ms)",
            initializer: name,
            path: path,
            duration_ms: duration,
            threshold_exceeded: duration >= VERY_SLOW_INITIALIZER_THRESHOLD ? 'critical' : 'warning'
          )
        end

        # ============================================
        # Helper Methods
        # ============================================
        def extract_initializer_name(path)
          return 'unknown' unless path

          # Extract filename without extension from path
          # e.g., "/app/config/initializers/devise.rb" -> "devise"
          File.basename(path.to_s, '.*')
        end
      end
    end
  end
end
