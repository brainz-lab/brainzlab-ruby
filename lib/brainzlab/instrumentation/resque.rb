# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module ResqueInstrumentation
      class << self
        def install!
          return unless defined?(::Resque)

          install_hooks!
          install_failure_backend!

          BrainzLab.debug_log('[Instrumentation] Resque instrumentation installed')
        end

        private

        def install_hooks!
          ::Resque.before_fork do |_job|
            # Clear any stale connections before forking
            BrainzLab::Recall.reset! if defined?(BrainzLab::Recall)
            BrainzLab::Pulse.reset! if defined?(BrainzLab::Pulse)
          end

          ::Resque.after_fork do |job|
            # Re-establish connections after forking
          end
        end

        def install_failure_backend!
          # Create a custom failure backend
          failure_backend = Class.new do
            def initialize(exception, worker, queue, payload)
              @exception = exception
              @worker = worker
              @queue = queue
              @payload = payload
            end

            def save
              job_class = @payload['class'] || 'Unknown'

              if BrainzLab.configuration.reflex_effectively_enabled?
                BrainzLab::Reflex.capture(@exception,
                                          tags: { job_class: job_class, queue: @queue, source: 'resque' },
                                          extra: {
                                            worker: @worker.to_s,
                                            args: @payload['args']
                                          })
              end

              return unless BrainzLab.configuration.flux_effectively_enabled?

              BrainzLab::Flux.increment('resque.job.failed', tags: { job_class: job_class, queue: @queue })
            end
          end

          # Add our failure backend to the chain
          return unless defined?(::Resque::Failure)

          ::Resque::Failure.backend = ::Resque::Failure::Multiple.new(
            ::Resque::Failure.backend,
            failure_backend
          )
        end
      end

      # Middleware module to include in Resque jobs
      module Middleware
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          def around_perform_brainzlab(*_args)
            job_class = name
            queue = Resque.queue_from_class(self) || 'default'
            started_at = Time.now

            BrainzLab::Context.current.set_context(
              job_class: job_class,
              queue: queue
            )

            begin
              yield
            ensure
              duration_ms = ((Time.now - started_at) * 1000).round(2)

              if BrainzLab.configuration.pulse_effectively_enabled?
                BrainzLab::Pulse.record_trace(
                  "job.#{job_class}",
                  kind: 'job',
                  started_at: started_at,
                  ended_at: Time.now,
                  job_class: job_class,
                  queue: queue
                )
              end

              if BrainzLab.configuration.flux_effectively_enabled?
                tags = { job_class: job_class, queue: queue }
                BrainzLab::Flux.distribution('resque.job.duration_ms', duration_ms, tags: tags)
                BrainzLab::Flux.increment('resque.job.processed', tags: tags)
              end

              BrainzLab.clear_context!
            end
          end
        end
      end
    end
  end
end
