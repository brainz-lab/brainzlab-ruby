# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module SolidQueueInstrumentation
      class << self
        def install!
          return unless defined?(::SolidQueue)

          install_job_instrumentation!
          install_worker_instrumentation!

          BrainzLab.debug_log("[Instrumentation] SolidQueue instrumentation installed")
        end

        private

        def install_job_instrumentation!
          return unless defined?(::ActiveJob::Base)

          ::ActiveJob::Base.class_eval do
            around_perform do |job, block|
              BrainzLab::Instrumentation::SolidQueueInstrumentation.around_perform(job, &block)
            end

            around_enqueue do |job, block|
              BrainzLab::Instrumentation::SolidQueueInstrumentation.around_enqueue(job, &block)
            end
          end
        end

        def install_worker_instrumentation!
          # Subscribe to ActiveSupport notifications for SolidQueue
          if defined?(::ActiveSupport::Notifications)
            ::ActiveSupport::Notifications.subscribe(/solid_queue/) do |name, start, finish, id, payload|
              handle_notification(name, start, finish, payload)
            end
          end
        end

        def handle_notification(name, start, finish, payload)
          duration_ms = ((finish - start) * 1000).round(2)

          case name
          when "perform.solid_queue"
            track_job_perform(payload, duration_ms)
          when "enqueue.solid_queue"
            track_job_enqueue(payload)
          when "discard.solid_queue"
            track_job_discard(payload)
          when "retry.solid_queue"
            track_job_retry(payload)
          end
        end

        def track_job_perform(payload, duration_ms)
          job_class = payload[:job]&.class&.name || payload[:job_class]
          queue = payload[:queue] || "default"

          # Track with Pulse
          if BrainzLab.configuration.pulse_effectively_enabled?
            BrainzLab::Pulse.record_trace(
              "job.#{job_class}",
              kind: "job",
              started_at: Time.now - (duration_ms / 1000.0),
              ended_at: Time.now,
              job_class: job_class,
              job_id: payload[:job_id],
              queue: queue,
              executions: payload[:executions] || 1,
              error: payload[:error].present?,
              error_class: payload[:error]&.class&.name,
              error_message: payload[:error]&.message
            )
          end

          # Track with Flux
          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { job_class: job_class, queue: queue }
            BrainzLab::Flux.distribution("solid_queue.job.duration_ms", duration_ms, tags: tags)
            BrainzLab::Flux.increment("solid_queue.job.processed", tags: tags)

            if payload[:error]
              BrainzLab::Flux.increment("solid_queue.job.failed", tags: tags)
            end
          end

          # Add breadcrumb for Reflex
          BrainzLab::Reflex.add_breadcrumb(
            "Job #{job_class} completed in #{duration_ms}ms",
            category: "job",
            level: payload[:error] ? :error : :info,
            data: { queue: queue, job_id: payload[:job_id], duration_ms: duration_ms }
          )
        end

        def track_job_enqueue(payload)
          job_class = payload[:job]&.class&.name || payload[:job_class]
          queue = payload[:queue] || "default"

          if BrainzLab.configuration.flux_effectively_enabled?
            BrainzLab::Flux.increment("solid_queue.job.enqueued", tags: { job_class: job_class, queue: queue })
          end
        end

        def track_job_discard(payload)
          job_class = payload[:job]&.class&.name || payload[:job_class]

          if BrainzLab.configuration.flux_effectively_enabled?
            BrainzLab::Flux.increment("solid_queue.job.discarded", tags: { job_class: job_class })
          end
        end

        def track_job_retry(payload)
          job_class = payload[:job]&.class&.name || payload[:job_class]

          if BrainzLab.configuration.flux_effectively_enabled?
            BrainzLab::Flux.increment("solid_queue.job.retried", tags: { job_class: job_class })
          end
        end
      end

      def self.around_perform(job)
        job_class = job.class.name
        queue = job.queue_name || "default"
        started_at = Time.now

        # Set context for the job
        BrainzLab::Context.current.set_context(
          job_class: job_class,
          job_id: job.job_id,
          queue: queue
        )

        begin
          yield
        rescue StandardError => e
          # Capture error with Reflex
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.capture(e,
              tags: { job_class: job_class, queue: queue },
              extra: {
                job_id: job.job_id,
                arguments: safe_arguments(job),
                executions: job.executions
              }
            )
          end
          raise
        ensure
          duration_ms = ((Time.now - started_at) * 1000).round(2)

          # Record trace
          if BrainzLab.configuration.pulse_effectively_enabled?
            BrainzLab::Pulse.record_trace(
              "job.#{job_class}",
              kind: "job",
              started_at: started_at,
              ended_at: Time.now,
              job_class: job_class,
              job_id: job.job_id,
              queue: queue,
              executions: job.executions
            )
          end

          # Record metrics
          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { job_class: job_class, queue: queue }
            BrainzLab::Flux.distribution("solid_queue.job.duration_ms", duration_ms, tags: tags)
          end

          # Clear context
          BrainzLab.clear_context!
        end
      end

      def self.around_enqueue(job)
        yield
      rescue StandardError => e
        if BrainzLab.configuration.reflex_effectively_enabled?
          BrainzLab::Reflex.capture(e,
            tags: { job_class: job.class.name, queue: job.queue_name },
            extra: { job_id: job.job_id, arguments: safe_arguments(job) }
          )
        end
        raise
      end

      def self.safe_arguments(job)
        args = job.arguments
        BrainzLab::Reflex.send(:filter_params, args) if args
      rescue StandardError
        "[Unable to serialize]"
      end
    end
  end
end
