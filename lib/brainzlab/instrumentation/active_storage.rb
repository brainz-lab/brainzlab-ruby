# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActiveStorage
      # Thresholds for slow operations (in milliseconds)
      SLOW_OPERATION_THRESHOLD = 500
      VERY_SLOW_OPERATION_THRESHOLD = 2000

      class << self
        def install!
          return unless defined?(::ActiveStorage)
          return if @installed

          # Core Active Storage events
          install_preview_subscriber!
          install_transform_subscriber!
          install_analyze_subscriber!

          # Storage service events
          install_service_upload_subscriber!
          install_service_download_subscriber!
          install_service_streaming_download_subscriber!
          install_service_delete_subscriber!
          install_service_delete_prefixed_subscriber!
          install_service_exist_subscriber!
          install_service_url_subscriber!
          install_service_download_chunk_subscriber!
          install_service_update_metadata_subscriber!

          @installed = true
          BrainzLab.debug_log('ActiveStorage instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # Preview (generating previews for files)
        # ============================================
        def install_preview_subscriber!
          ActiveSupport::Notifications.subscribe('preview.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_preview(event)
          end
        end

        def handle_preview(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Record breadcrumb
          record_storage_breadcrumb('preview', key, duration)

          # Add Pulse span
          record_storage_span(event, 'preview', key, duration)

          # Log slow operations
          log_slow_operation('preview', key, duration) if duration >= SLOW_OPERATION_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage preview instrumentation failed: #{e.message}")
        end

        # ============================================
        # Transform (image transformations)
        # ============================================
        def install_transform_subscriber!
          ActiveSupport::Notifications.subscribe('transform.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_transform(event)
          end
        end

        def handle_transform(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Record breadcrumb
          record_storage_breadcrumb('transform', key, duration)

          # Add Pulse span
          record_storage_span(event, 'transform', key, duration)

          # Log slow operations
          log_slow_operation('transform', key, duration) if duration >= SLOW_OPERATION_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage transform instrumentation failed: #{e.message}")
        end

        # ============================================
        # Analyze (file analysis - dimensions, duration, etc.)
        # ============================================
        def install_analyze_subscriber!
          ActiveSupport::Notifications.subscribe('analyze.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_analyze(event)
          end
        end

        def handle_analyze(event)
          payload = event.payload
          duration = event.duration.round(2)

          analyzer = payload[:analyzer]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Storage analyze: #{analyzer} (#{duration}ms)",
              category: 'storage.analyze',
              level: duration >= SLOW_OPERATION_THRESHOLD ? :warning : :info,
              data: {
                analyzer: analyzer,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_storage_span(event, 'analyze', analyzer, duration, analyzer: analyzer)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage analyze instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Upload
        # ============================================
        def install_service_upload_subscriber!
          ActiveSupport::Notifications.subscribe('service_upload.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_upload(event)
          end
        end

        def handle_service_upload(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]
          checksum = payload[:checksum]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            level = case duration
                    when 0...SLOW_OPERATION_THRESHOLD then :info
                    when SLOW_OPERATION_THRESHOLD...VERY_SLOW_OPERATION_THRESHOLD then :warning
                    else :error
                    end

            BrainzLab::Reflex.add_breadcrumb(
              "Storage upload: #{truncate_key(key)} (#{duration}ms)",
              category: 'storage.upload',
              level: level,
              data: {
                key: truncate_key(key),
                service: service,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_service_span(event, 'upload', key, duration, service: service)

          # Log slow uploads
          log_slow_operation('upload', key, duration, service: service) if duration >= SLOW_OPERATION_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_upload instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Download
        # ============================================
        def install_service_download_subscriber!
          ActiveSupport::Notifications.subscribe('service_download.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_download(event)
          end
        end

        def handle_service_download(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]

          # Record breadcrumb
          record_storage_breadcrumb('download', key, duration, service: service)

          # Add Pulse span
          record_service_span(event, 'download', key, duration, service: service)

          # Log slow downloads
          log_slow_operation('download', key, duration, service: service) if duration >= SLOW_OPERATION_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_download instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Streaming Download
        # ============================================
        def install_service_streaming_download_subscriber!
          ActiveSupport::Notifications.subscribe('service_streaming_download.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_streaming_download(event)
          end
        end

        def handle_service_streaming_download(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]

          # Record breadcrumb
          record_storage_breadcrumb('streaming_download', key, duration, service: service)

          # Add Pulse span
          record_service_span(event, 'streaming_download', key, duration, service: service)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_streaming_download instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Delete
        # ============================================
        def install_service_delete_subscriber!
          ActiveSupport::Notifications.subscribe('service_delete.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_delete(event)
          end
        end

        def handle_service_delete(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]

          # Record breadcrumb
          record_storage_breadcrumb('delete', key, duration, service: service)

          # Add Pulse span
          record_service_span(event, 'delete', key, duration, service: service)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_delete instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Delete Prefixed (bulk delete)
        # ============================================
        def install_service_delete_prefixed_subscriber!
          ActiveSupport::Notifications.subscribe('service_delete_prefixed.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_delete_prefixed(event)
          end
        end

        def handle_service_delete_prefixed(event)
          payload = event.payload
          duration = event.duration.round(2)

          prefix = payload[:prefix]
          service = payload[:service]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Storage delete prefixed: #{truncate_key(prefix)}* (#{duration}ms)",
              category: 'storage.delete_prefixed',
              level: :warning,
              data: {
                prefix: truncate_key(prefix),
                service: service,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_service_span(event, 'delete_prefixed', prefix, duration, service: service)

          # Log to Recall - bulk deletes are significant
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.info(
              "Storage bulk delete by prefix",
              prefix: truncate_key(prefix),
              service: service,
              duration_ms: duration
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_delete_prefixed instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Exist
        # ============================================
        def install_service_exist_subscriber!
          ActiveSupport::Notifications.subscribe('service_exist.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_exist(event)
          end
        end

        def handle_service_exist(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]
          exist = payload[:exist]

          # Only track if slow (existence checks are frequent)
          return if duration < 5

          # Add Pulse span
          record_service_span(event, 'exist', key, duration, service: service, exist: exist)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_exist instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service URL (generating signed URLs)
        # ============================================
        def install_service_url_subscriber!
          ActiveSupport::Notifications.subscribe('service_url.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_url(event)
          end
        end

        def handle_service_url(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]

          # Only track if slow (URL generation should be fast)
          return if duration < 10

          # Add Pulse span for slow URL generations
          record_service_span(event, 'url', key, duration, service: service)

          # Log slow URL generations
          if duration >= 50 && BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Slow storage URL generation",
              key: truncate_key(key),
              service: service,
              duration_ms: duration
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_url instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Download Chunk (chunked downloads)
        # ============================================
        def install_service_download_chunk_subscriber!
          ActiveSupport::Notifications.subscribe('service_download_chunk.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_download_chunk(event)
          end
        end

        def handle_service_download_chunk(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]
          range = payload[:range]

          # Only track slow chunks
          return if duration < 10

          # Add Pulse span for slow chunk downloads
          record_service_span(event, 'download_chunk', key, duration, service: service, range: range.to_s)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_download_chunk instrumentation failed: #{e.message}")
        end

        # ============================================
        # Service Update Metadata
        # ============================================
        def install_service_update_metadata_subscriber!
          ActiveSupport::Notifications.subscribe('service_update_metadata.active_storage') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_service_update_metadata(event)
          end
        end

        def handle_service_update_metadata(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          service = payload[:service]
          content_type = payload[:content_type]
          disposition = payload[:disposition]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Storage metadata update: #{truncate_key(key)} (#{duration}ms)",
              category: 'storage.metadata',
              level: :info,
              data: {
                key: truncate_key(key),
                service: service,
                content_type: content_type,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_service_span(event, 'update_metadata', key, duration,
                              service: service, content_type: content_type)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveStorage service_update_metadata instrumentation failed: #{e.message}")
        end

        # ============================================
        # Recording Helpers
        # ============================================
        def record_storage_breadcrumb(operation, key, duration, service: nil)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          level = case duration
                  when 0...SLOW_OPERATION_THRESHOLD then :info
                  when SLOW_OPERATION_THRESHOLD...VERY_SLOW_OPERATION_THRESHOLD then :warning
                  else :error
                  end

          BrainzLab::Reflex.add_breadcrumb(
            "Storage #{operation}: #{truncate_key(key)} (#{duration}ms)",
            category: "storage.#{operation}",
            level: level,
            data: {
              key: truncate_key(key),
              service: service,
              duration_ms: duration
            }.compact
          )
        end

        def record_storage_span(event, operation, key, duration, **extra)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "storage.#{operation}",
            kind: 'storage',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'storage.operation' => operation,
              'storage.key' => truncate_key(key)
            }.merge(extra.transform_keys { |k| "storage.#{k}" }).compact
          }

          tracer.current_spans << span_data
        end

        def record_service_span(event, operation, key, duration, service: nil, **extra)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "storage.service.#{operation}",
            kind: 'storage',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'storage.operation' => operation,
              'storage.key' => truncate_key(key),
              'storage.service' => service
            }.merge(extra.transform_keys { |k| "storage.#{k}" }).compact
          }

          tracer.current_spans << span_data
        end

        def log_slow_operation(operation, key, duration, service: nil)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_OPERATION_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow storage #{operation}: #{truncate_key(key)} (#{duration}ms)",
            operation: operation,
            key: truncate_key(key),
            service: service,
            duration_ms: duration,
            threshold_exceeded: duration >= VERY_SLOW_OPERATION_THRESHOLD ? 'critical' : 'warning'
          )
        end

        # ============================================
        # Helper Methods
        # ============================================
        def truncate_key(key, max_length = 100)
          return 'unknown' unless key

          key_str = key.to_s
          if key_str.length > max_length
            "#{key_str[0, max_length - 3]}..."
          else
            key_str
          end
        end
      end
    end
  end
end
