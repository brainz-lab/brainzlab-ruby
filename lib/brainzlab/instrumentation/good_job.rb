# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module GoodJobInstrumentation
      class << self
        def install!
          return unless defined?(::GoodJob)

          install_notifier!
          install_middleware!

          BrainzLab.debug_log("[Instrumentation] GoodJob instrumentation installed")
        end

        private

        def install_notifier!
          return unless defined?(::ActiveSupport::Notifications)

          # GoodJob emits ActiveSupport notifications
          ::ActiveSupport::Notifications.subscribe("perform_job.good_job") do |*args|
            event = ::ActiveSupport::Notifications::Event.new(*args)
            handle_perform(event)
          end

          ::ActiveSupport::Notifications.subscribe("finished_job_task.good_job") do |*args|
            event = ::ActiveSupport::Notifications::Event.new(*args)
            handle_finished(event)
          end
        end

        def install_middleware!
          return unless defined?(::GoodJob::Adapter)

          # Add our callback to GoodJob
          if ::GoodJob.respond_to?(:on_thread_error)
            ::GoodJob.on_thread_error = ->(error) do
              BrainzLab::Reflex.capture(error, tags: { source: "good_job" }) if BrainzLab.configuration.reflex_effectively_enabled?
            end
          end
        end

        def handle_perform(event)
          payload = event.payload
          job = payload[:job]
          job_class = job&.class&.name || payload[:job_class] || "Unknown"
          queue = job&.queue_name || payload[:queue_name] || "default"
          duration_ms = event.duration.round(2)

          # Track with Pulse
          if BrainzLab.configuration.pulse_effectively_enabled?
            BrainzLab::Pulse.record_trace(
              "job.#{job_class}",
              kind: "job",
              started_at: event.time,
              ended_at: event.end,
              job_class: job_class,
              job_id: job&.job_id || payload[:job_id],
              queue: queue,
              error: payload[:error].present?,
              error_class: payload[:error]&.class&.name,
              error_message: payload[:error]&.message
            )
          end

          # Track with Flux
          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { job_class: job_class, queue: queue }
            BrainzLab::Flux.distribution("good_job.job.duration_ms", duration_ms, tags: tags)
            BrainzLab::Flux.increment("good_job.job.processed", tags: tags)

            if payload[:error]
              BrainzLab::Flux.increment("good_job.job.failed", tags: tags)
            end
          end

          # Capture error with Reflex
          if payload[:error] && BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.capture(payload[:error],
              tags: { job_class: job_class, queue: queue, source: "good_job" },
              extra: { job_id: job&.job_id, duration_ms: duration_ms }
            )
          end
        end

        def handle_finished(event)
          payload = event.payload

          if BrainzLab.configuration.flux_effectively_enabled?
            result = payload[:result]
            if result == :discarded
              BrainzLab::Flux.increment("good_job.job.discarded")
            elsif result == :retried
              BrainzLab::Flux.increment("good_job.job.retried")
            end
          end
        end
      end
    end
  end
end
