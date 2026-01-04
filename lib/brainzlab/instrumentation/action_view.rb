# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActionView
      # Thresholds for slow render detection (in milliseconds)
      SLOW_RENDER_THRESHOLD = 50
      VERY_SLOW_RENDER_THRESHOLD = 200

      # Only track partials rendered more than this many times
      COLLECTION_TRACKING_THRESHOLD = 10

      class << self
        def install!
          return unless defined?(::ActionView)
          return if @installed

          install_render_template_subscriber!
          install_render_partial_subscriber!
          install_render_collection_subscriber!
          install_render_layout_subscriber!

          @installed = true
          BrainzLab.debug_log('ActionView instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # Render Template
        # ============================================
        def install_render_template_subscriber!
          ActiveSupport::Notifications.subscribe('render_template.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_render_template(event)
          end
        end

        def handle_render_template(event)
          payload = event.payload
          duration = event.duration.round(2)

          identifier = payload[:identifier]
          layout = payload[:layout]

          # Extract template name from full path
          template_name = extract_template_name(identifier)

          # Add breadcrumb for Reflex
          record_render_breadcrumb('template', template_name, duration, layout: layout)

          # Add span to Pulse
          record_render_span(event, 'template', template_name, duration, layout: layout)

          # Log slow renders to Recall
          log_slow_render('template', template_name, duration) if duration >= SLOW_RENDER_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActionView render_template instrumentation failed: #{e.message}")
        end

        # ============================================
        # Render Partial
        # ============================================
        def install_render_partial_subscriber!
          ActiveSupport::Notifications.subscribe('render_partial.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_render_partial(event)
          end
        end

        def handle_render_partial(event)
          payload = event.payload
          duration = event.duration.round(2)

          identifier = payload[:identifier]
          template_name = extract_template_name(identifier)

          # Skip very fast partials to reduce noise
          return if duration < 1 && !payload[:cache_hit]

          # Add breadcrumb for Reflex
          record_render_breadcrumb('partial', template_name, duration, cached: payload[:cache_hit])

          # Add span to Pulse
          record_render_span(event, 'partial', template_name, duration, cached: payload[:cache_hit])

          # Log slow renders to Recall
          log_slow_render('partial', template_name, duration) if duration >= SLOW_RENDER_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActionView render_partial instrumentation failed: #{e.message}")
        end

        # ============================================
        # Render Collection
        # ============================================
        def install_render_collection_subscriber!
          ActiveSupport::Notifications.subscribe('render_collection.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_render_collection(event)
          end
        end

        def handle_render_collection(event)
          payload = event.payload
          duration = event.duration.round(2)

          identifier = payload[:identifier]
          count = payload[:count] || 0
          cache_hits = payload[:cache_hits] || 0

          template_name = extract_template_name(identifier)

          # Add breadcrumb for significant collections
          if count >= COLLECTION_TRACKING_THRESHOLD || duration >= SLOW_RENDER_THRESHOLD
            record_collection_breadcrumb(template_name, duration, count, cache_hits)
          end

          # Add span to Pulse
          record_collection_span(event, template_name, duration, count, cache_hits)

          # Log slow collection renders to Recall
          if duration >= SLOW_RENDER_THRESHOLD
            log_slow_collection_render(template_name, duration, count, cache_hits)
          end

          # Track potential N+1 view pattern (many partials rendered)
          track_collection_performance(template_name, count, duration) if count >= 50
        rescue StandardError => e
          BrainzLab.debug_log("ActionView render_collection instrumentation failed: #{e.message}")
        end

        # ============================================
        # Render Layout
        # ============================================
        def install_render_layout_subscriber!
          ActiveSupport::Notifications.subscribe('render_layout.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_render_layout(event)
          end
        end

        def handle_render_layout(event)
          payload = event.payload
          duration = event.duration.round(2)

          identifier = payload[:identifier]
          layout_name = extract_template_name(identifier)

          # Only track if significant
          return if duration < 5

          # Add span to Pulse (layouts are important for understanding request timing)
          if BrainzLab.configuration.pulse_effectively_enabled?
            tracer = BrainzLab::Pulse.tracer
            if tracer.current_trace
              span_data = {
                span_id: SecureRandom.uuid,
                name: "view.layout.#{layout_name}",
                kind: 'view',
                started_at: event.time,
                ended_at: event.end,
                duration_ms: duration,
                error: false,
                data: {
                  'view.type' => 'layout',
                  'view.template' => layout_name
                }
              }

              tracer.current_spans << span_data
            end
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionView render_layout instrumentation failed: #{e.message}")
        end

        # ============================================
        # Recording Helpers
        # ============================================
        def record_render_breadcrumb(type, template_name, duration, layout: nil, cached: nil)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          level = case duration
                  when 0...SLOW_RENDER_THRESHOLD then :info
                  when SLOW_RENDER_THRESHOLD...VERY_SLOW_RENDER_THRESHOLD then :warning
                  else :error
                  end

          message = if cached
                      "Render #{type}: #{template_name} (cached)"
                    else
                      "Render #{type}: #{template_name} (#{duration}ms)"
                    end

          BrainzLab::Reflex.add_breadcrumb(
            message,
            category: "view.#{type}",
            level: level,
            data: {
              template: template_name,
              type: type,
              duration_ms: duration,
              layout: layout,
              cached: cached
            }.compact
          )
        end

        def record_render_span(event, type, template_name, duration, layout: nil, cached: nil)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "view.#{type}.#{template_name}",
            kind: 'view',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'view.type' => type,
              'view.template' => template_name,
              'view.layout' => layout,
              'view.cached' => cached
            }.compact
          }

          tracer.current_spans << span_data
        end

        def record_collection_breadcrumb(template_name, duration, count, cache_hits)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          level = case duration
                  when 0...SLOW_RENDER_THRESHOLD then :info
                  when SLOW_RENDER_THRESHOLD...VERY_SLOW_RENDER_THRESHOLD then :warning
                  else :error
                  end

          cache_info = cache_hits > 0 ? " (#{cache_hits}/#{count} cached)" : ""

          BrainzLab::Reflex.add_breadcrumb(
            "Render collection: #{template_name} x#{count}#{cache_info} (#{duration}ms)",
            category: 'view.collection',
            level: level,
            data: {
              template: template_name,
              count: count,
              cache_hits: cache_hits,
              duration_ms: duration,
              avg_per_item_ms: count > 0 ? (duration / count).round(2) : nil
            }.compact
          )
        end

        def record_collection_span(event, template_name, duration, count, cache_hits)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "view.collection.#{template_name}",
            kind: 'view',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'view.type' => 'collection',
              'view.template' => template_name,
              'view.count' => count,
              'view.cache_hits' => cache_hits,
              'view.avg_per_item_ms' => count > 0 ? (duration / count).round(2) : nil
            }.compact
          }

          tracer.current_spans << span_data
        end

        # ============================================
        # Logging Helpers
        # ============================================
        def log_slow_render(type, template_name, duration)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_RENDER_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow #{type} render: #{template_name} (#{duration}ms)",
            template: template_name,
            type: type,
            duration_ms: duration,
            threshold_exceeded: duration >= VERY_SLOW_RENDER_THRESHOLD ? 'critical' : 'warning'
          )
        end

        def log_slow_collection_render(template_name, duration, count, cache_hits)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_RENDER_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow collection render: #{template_name} x#{count} (#{duration}ms)",
            template: template_name,
            type: 'collection',
            count: count,
            cache_hits: cache_hits,
            duration_ms: duration,
            avg_per_item_ms: count > 0 ? (duration / count).round(2) : nil,
            threshold_exceeded: duration >= VERY_SLOW_RENDER_THRESHOLD ? 'critical' : 'warning'
          )
        end

        def track_collection_performance(template_name, count, duration)
          avg_per_item = count > 0 ? (duration / count).round(2) : 0

          # If average time per item is high, this might indicate N+1 in the partial
          if avg_per_item > 5 # More than 5ms per item is suspicious
            if BrainzLab.configuration.reflex_effectively_enabled?
              BrainzLab::Reflex.add_breadcrumb(
                "Slow collection items: #{template_name} (#{avg_per_item}ms/item)",
                category: 'view.performance',
                level: :warning,
                data: {
                  template: template_name,
                  count: count,
                  duration_ms: duration,
                  avg_per_item_ms: avg_per_item,
                  suggestion: 'Consider caching, eager loading, or optimizing the partial'
                }
              )
            end

            if BrainzLab.configuration.recall_effectively_enabled?
              BrainzLab::Recall.warn(
                "Collection partial may have N+1 or performance issue",
                template: template_name,
                count: count,
                duration_ms: duration,
                avg_per_item_ms: avg_per_item
              )
            end
          end
        end

        # ============================================
        # Helper Methods
        # ============================================
        def extract_template_name(identifier)
          return 'unknown' unless identifier

          # Remove the full path and extract just the template name
          # e.g., "/app/views/users/show.html.erb" -> "users/show"
          path = identifier.to_s

          # Try to extract from app/views path
          if path.include?('app/views/')
            template = path.split('app/views/').last
            # Remove extension
            template.sub(/\.[^.]+\z/, '').sub(/\.[^.]+\z/, '')
          else
            # Fallback: just use the filename
            File.basename(path).sub(/\.[^.]+\z/, '').sub(/\.[^.]+\z/, '')
          end
        end
      end
    end
  end
end
