# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActiveJob
      # Thresholds for slow job detection (in milliseconds)
      SLOW_JOB_THRESHOLD = 5000    # 5 seconds
      VERY_SLOW_JOB_THRESHOLD = 30_000  # 30 seconds

      class << self
        def install!
          return unless defined?(::ActiveJob)
          return if @installed

          install_enqueue_subscriber!
          install_enqueue_at_subscriber!
          install_enqueue_all_subscriber!
          install_enqueue_retry_subscriber!
          install_perform_start_subscriber!
          install_perform_subscriber!
          install_retry_stopped_subscriber!
          install_discard_subscriber!

          @installed = true
          BrainzLab.debug_log('ActiveJob instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # Enqueue (job added to queue)
        # ============================================
        def install_enqueue_subscriber!
          ActiveSupport::Notifications.subscribe('enqueue.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_enqueue(event)
          end
        end

        def handle_enqueue(event)
          payload = event.payload
          job = payload[:job]
          adapter = payload[:adapter]

          job_class = job.class.name
          job_id = job.job_id
          queue = job.queue_name

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Job enqueued: #{job_class}",
              category: 'job.enqueue',
              level: :info,
              data: {
                job_class: job_class,
                job_id: job_id,
                queue: queue,
                adapter: adapter.class.name
              }.compact
            )
          end

          # Add Pulse span if trace is active
          record_enqueue_span(event, job_class, job_id, queue)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob enqueue instrumentation failed: #{e.message}")
        end

        # ============================================
        # Enqueue At (scheduled job)
        # ============================================
        def install_enqueue_at_subscriber!
          ActiveSupport::Notifications.subscribe('enqueue_at.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_enqueue_at(event)
          end
        end

        def handle_enqueue_at(event)
          payload = event.payload
          job = payload[:job]

          job_class = job.class.name
          job_id = job.job_id
          queue = job.queue_name
          scheduled_at = job.scheduled_at

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            scheduled_in = scheduled_at ? ((scheduled_at - Time.now) / 60).round(1) : nil

            BrainzLab::Reflex.add_breadcrumb(
              "Job scheduled: #{job_class}#{scheduled_in ? " (in #{scheduled_in}min)" : ''}",
              category: 'job.schedule',
              level: :info,
              data: {
                job_class: job_class,
                job_id: job_id,
                queue: queue,
                scheduled_at: scheduled_at&.iso8601
              }.compact
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob enqueue_at instrumentation failed: #{e.message}")
        end

        # ============================================
        # Enqueue All (bulk job enqueueing)
        # Fired when using ActiveJob.perform_all_later
        # ============================================
        def install_enqueue_all_subscriber!
          ActiveSupport::Notifications.subscribe('enqueue_all.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_enqueue_all(event)
          end
        end

        def handle_enqueue_all(event)
          payload = event.payload
          adapter = payload[:adapter]
          jobs = payload[:jobs] || []

          job_count = jobs.size
          job_classes = jobs.map { |j| j.class.name }.tally

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            class_summary = job_classes.map { |k, v| "#{k}(#{v})" }.join(', ')

            BrainzLab::Reflex.add_breadcrumb(
              "Bulk enqueue: #{job_count} jobs",
              category: 'job.enqueue_all',
              level: :info,
              data: {
                job_count: job_count,
                job_classes: class_summary,
                adapter: adapter.class.name
              }.compact
            )
          end

          # Add Pulse span if trace is active
          record_enqueue_all_span(event, job_count, job_classes)

          # Log to Recall for significant bulk operations
          if job_count >= 10 && BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.info(
              "Bulk job enqueue: #{job_count} jobs",
              job_count: job_count,
              job_classes: job_classes,
              adapter: adapter.class.name
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob enqueue_all instrumentation failed: #{e.message}")
        end

        # ============================================
        # Enqueue Retry (job retry scheduled)
        # ============================================
        def install_enqueue_retry_subscriber!
          ActiveSupport::Notifications.subscribe('enqueue_retry.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_enqueue_retry(event)
          end
        end

        def handle_enqueue_retry(event)
          payload = event.payload
          job = payload[:job]
          error = payload[:error]
          wait = payload[:wait]

          job_class = job.class.name
          job_id = job.job_id
          executions = job.executions

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Job retry scheduled: #{job_class} (attempt #{executions + 1})",
              category: 'job.retry',
              level: :warning,
              data: {
                job_class: job_class,
                job_id: job_id,
                executions: executions,
                wait_seconds: wait,
                error_class: error&.class&.name,
                error_message: error&.message&.slice(0, 200)
              }.compact
            )
          end

          # Log retry to Recall
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Job retry scheduled: #{job_class}",
              job_class: job_class,
              job_id: job_id,
              executions: executions,
              wait_seconds: wait,
              error_class: error&.class&.name,
              error_message: error&.message&.slice(0, 500)
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob enqueue_retry instrumentation failed: #{e.message}")
        end

        # ============================================
        # Perform Start (job execution begins)
        # ============================================
        def install_perform_start_subscriber!
          ActiveSupport::Notifications.subscribe('perform_start.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_perform_start(event)
          end
        end

        def handle_perform_start(event)
          payload = event.payload
          job = payload[:job]

          job_class = job.class.name
          job_id = job.job_id
          queue = job.queue_name
          executions = job.executions

          # Store start time for queue wait calculation
          Thread.current[:brainzlab_job_starts] ||= {}
          Thread.current[:brainzlab_job_starts][job_id] = {
            started_at: event.time,
            enqueued_at: job.enqueued_at
          }

          # Calculate queue wait time if enqueued_at is available
          queue_wait_ms = nil
          if job.enqueued_at
            queue_wait_ms = ((event.time - job.enqueued_at) * 1000).round(2)
          end

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Job started: #{job_class}#{executions > 1 ? " (attempt #{executions})" : ''}",
              category: 'job.start',
              level: :info,
              data: {
                job_class: job_class,
                job_id: job_id,
                queue: queue,
                executions: executions,
                queue_wait_ms: queue_wait_ms
              }.compact
            )
          end

          # Start Pulse trace for job
          start_job_trace(job, queue_wait_ms)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob perform_start instrumentation failed: #{e.message}")
        end

        # ============================================
        # Perform (job execution complete)
        # ============================================
        def install_perform_subscriber!
          ActiveSupport::Notifications.subscribe('perform.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_perform(event)
          end
        end

        def handle_perform(event)
          payload = event.payload
          job = payload[:job]
          exception = payload[:exception_object]
          duration = event.duration.round(2)

          job_class = job.class.name
          job_id = job.job_id
          queue = job.queue_name
          executions = job.executions

          # Get stored start info
          job_starts = Thread.current[:brainzlab_job_starts] || {}
          start_info = job_starts.delete(job_id) || {}
          queue_wait_ms = nil
          if start_info[:enqueued_at]
            queue_wait_ms = ((start_info[:started_at] - start_info[:enqueued_at]) * 1000).round(2)
          end

          # Determine level based on outcome and duration
          level = if exception
                    :error
                  elsif duration >= SLOW_JOB_THRESHOLD
                    :warning
                  else
                    :info
                  end

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            message = if exception
                        "Job failed: #{job_class} (#{duration}ms)"
                      else
                        "Job completed: #{job_class} (#{duration}ms)"
                      end

            BrainzLab::Reflex.add_breadcrumb(
              message,
              category: 'job.perform',
              level: level,
              data: {
                job_class: job_class,
                job_id: job_id,
                queue: queue,
                executions: executions,
                duration_ms: duration,
                queue_wait_ms: queue_wait_ms,
                error: exception ? true : false,
                error_class: exception&.class&.name,
                error_message: exception&.message&.slice(0, 200)
              }.compact
            )
          end

          # Finish Pulse trace
          finish_job_trace(exception)

          # Log to Recall
          log_job_completion(job_class, job_id, queue, duration, exception, queue_wait_ms)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob perform instrumentation failed: #{e.message}")
        end

        # ============================================
        # Retry Stopped (all retries exhausted)
        # ============================================
        def install_retry_stopped_subscriber!
          ActiveSupport::Notifications.subscribe('retry_stopped.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_retry_stopped(event)
          end
        end

        def handle_retry_stopped(event)
          payload = event.payload
          job = payload[:job]
          error = payload[:error]

          job_class = job.class.name
          job_id = job.job_id
          executions = job.executions

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Job retries exhausted: #{job_class} (#{executions} attempts)",
              category: 'job.retry_stopped',
              level: :error,
              data: {
                job_class: job_class,
                job_id: job_id,
                executions: executions,
                error_class: error&.class&.name,
                error_message: error&.message&.slice(0, 200)
              }.compact
            )
          end

          # Log to Recall - this is a critical event
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.error(
              "Job retries exhausted: #{job_class}",
              job_class: job_class,
              job_id: job_id,
              executions: executions,
              error_class: error&.class&.name,
              error_message: error&.message
            )
          end

          # Capture error in Reflex
          if error && BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.capture(
              error,
              tags: { job_class: job_class, job_id: job_id },
              extra: { executions: executions, retry_stopped: true }
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob retry_stopped instrumentation failed: #{e.message}")
        end

        # ============================================
        # Discard (job discarded due to error)
        # ============================================
        def install_discard_subscriber!
          ActiveSupport::Notifications.subscribe('discard.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_discard(event)
          end
        end

        def handle_discard(event)
          payload = event.payload
          job = payload[:job]
          error = payload[:error]

          job_class = job.class.name
          job_id = job.job_id

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Job discarded: #{job_class}",
              category: 'job.discard',
              level: :error,
              data: {
                job_class: job_class,
                job_id: job_id,
                error_class: error&.class&.name,
                error_message: error&.message&.slice(0, 200)
              }.compact
            )
          end

          # Log to Recall
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.error(
              "Job discarded: #{job_class}",
              job_class: job_class,
              job_id: job_id,
              error_class: error&.class&.name,
              error_message: error&.message
            )
          end

          # Capture error in Reflex
          if error && BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.capture(
              error,
              tags: { job_class: job_class, job_id: job_id },
              extra: { discarded: true }
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveJob discard instrumentation failed: #{e.message}")
        end

        # ============================================
        # Pulse Trace Helpers
        # ============================================
        def start_job_trace(job, queue_wait_ms)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          BrainzLab::Pulse.start_trace(
            job.class.name,
            kind: 'job',
            job_class: job.class.name,
            job_id: job.job_id,
            queue: job.queue_name,
            executions: job.executions,
            queue_wait_ms: queue_wait_ms
          )
        end

        def finish_job_trace(exception)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          BrainzLab::Pulse.finish_trace(
            error: exception ? true : false,
            error_class: exception&.class&.name,
            error_message: exception&.message
          )
        end

        def record_enqueue_span(event, job_class, job_id, queue)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "job.enqueue.#{job_class}",
            kind: 'job',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: event.duration.round(2),
            error: false,
            data: {
              'job.class' => job_class,
              'job.id' => job_id,
              'job.queue' => queue,
              'job.operation' => 'enqueue'
            }
          }

          tracer.current_spans << span_data
        end

        def record_enqueue_all_span(event, job_count, job_classes)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'job.enqueue_all',
            kind: 'job',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: event.duration.round(2),
            error: false,
            data: {
              'job.operation' => 'enqueue_all',
              'job.count' => job_count,
              'job.classes' => job_classes.keys.join(', ')
            }
          }

          tracer.current_spans << span_data
        end

        # ============================================
        # Logging Helpers
        # ============================================
        def log_job_completion(job_class, job_id, queue, duration, exception, queue_wait_ms)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          if exception
            BrainzLab::Recall.error(
              "Job failed: #{job_class}",
              job_class: job_class,
              job_id: job_id,
              queue: queue,
              duration_ms: duration,
              queue_wait_ms: queue_wait_ms,
              error_class: exception.class.name,
              error_message: exception.message
            )
          elsif duration >= SLOW_JOB_THRESHOLD
            level = duration >= VERY_SLOW_JOB_THRESHOLD ? :error : :warn
            BrainzLab::Recall.send(
              level,
              "Slow job: #{job_class} (#{duration}ms)",
              job_class: job_class,
              job_id: job_id,
              queue: queue,
              duration_ms: duration,
              queue_wait_ms: queue_wait_ms,
              threshold_exceeded: duration >= VERY_SLOW_JOB_THRESHOLD ? 'critical' : 'warning'
            )
          end
        end
      end
    end
  end
end
