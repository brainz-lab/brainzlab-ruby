# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module AWSInstrumentation
      class << self
        def install!
          return unless defined?(::Aws)

          install_plugin!

          BrainzLab.debug_log("[Instrumentation] AWS SDK instrumentation installed")
        end

        private

        def install_plugin!
          # AWS SDK v3 uses plugins
          if defined?(::Aws::Plugins)
            ::Aws.config[:plugins] ||= []
            ::Aws.config[:plugins] << BrainzLabPlugin unless ::Aws.config[:plugins].include?(BrainzLabPlugin)
          end

          # Also hook into Seahorse for lower-level tracking
          if defined?(::Seahorse::Client::Base)
            install_seahorse_handler!
          end
        end

        def install_seahorse_handler!
          handler_class = Class.new(::Seahorse::Client::Handler) do
            def call(context)
              started_at = Time.now
              service = context.client.class.name.split("::")[1] || "AWS"
              operation = context.operation_name.to_s

              begin
                response = @handler.call(context)
                track_success(service, operation, started_at, context, response)
                response
              rescue StandardError => e
                track_error(service, operation, started_at, context, e)
                raise
              end
            end

            private

            def track_success(service, operation, started_at, context, response)
              duration_ms = ((Time.now - started_at) * 1000).round(2)

              BrainzLab::Reflex.add_breadcrumb(
                "AWS #{service}.#{operation}",
                category: "aws",
                level: :info,
                data: {
                  service: service,
                  operation: operation,
                  region: context.config.region,
                  duration_ms: duration_ms
                }
              )

              if BrainzLab.configuration.flux_effectively_enabled?
                tags = { service: service, operation: operation, region: context.config.region }
                BrainzLab::Flux.distribution("aws.duration_ms", duration_ms, tags: tags)
                BrainzLab::Flux.increment("aws.requests", tags: tags)
              end
            end

            def track_error(service, operation, started_at, context, error)
              duration_ms = ((Time.now - started_at) * 1000).round(2)

              BrainzLab::Reflex.add_breadcrumb(
                "AWS #{service}.#{operation} failed: #{error.message}",
                category: "aws",
                level: :error,
                data: {
                  service: service,
                  operation: operation,
                  error: error.class.name
                }
              )

              if BrainzLab.configuration.flux_effectively_enabled?
                tags = { service: service, operation: operation, error_class: error.class.name }
                BrainzLab::Flux.increment("aws.errors", tags: tags)
              end
            end
          end

          ::Seahorse::Client::Base.add_plugin(
            Class.new(::Seahorse::Client::Plugin) do
              define_method(:add_handlers) do |handlers, config|
                handlers.add(handler_class, step: :validate, priority: 0)
              end
            end
          )
        end
      end

      # Aws SDK Plugin
      class BrainzLabPlugin
        def self.add_handlers(handlers, config)
          handlers.add(Handler, step: :validate, priority: 0)
        end

        class Handler
          def initialize(handler)
            @handler = handler
          end

          def call(context)
            started_at = Time.now
            service = extract_service(context)
            operation = context.operation_name.to_s

            begin
              response = @handler.call(context)
              track_request(service, operation, started_at, context, response)
              response
            rescue StandardError => e
              track_error(service, operation, started_at, context, e)
              raise
            end
          end

          private

          def extract_service(context)
            context.client.class.name.to_s.split("::")[1] || "AWS"
          end

          def track_request(service, operation, started_at, context, response)
            duration_ms = ((Time.now - started_at) * 1000).round(2)
            region = context.config.region rescue "unknown"

            BrainzLab::Reflex.add_breadcrumb(
              "AWS #{service}.#{operation}",
              category: "aws",
              level: :info,
              data: {
                service: service,
                operation: operation,
                region: region,
                duration_ms: duration_ms,
                retries: context.retries
              }
            )

            if BrainzLab.configuration.flux_effectively_enabled?
              tags = { service: service, operation: operation, region: region }
              BrainzLab::Flux.distribution("aws.duration_ms", duration_ms, tags: tags)
              BrainzLab::Flux.increment("aws.requests", tags: tags)

              if context.retries > 0
                BrainzLab::Flux.increment("aws.retries", value: context.retries, tags: tags)
              end
            end
          end

          def track_error(service, operation, started_at, context, error)
            BrainzLab::Reflex.add_breadcrumb(
              "AWS #{service}.#{operation} failed",
              category: "aws",
              level: :error,
              data: { service: service, operation: operation, error: error.class.name }
            )

            if BrainzLab.configuration.flux_effectively_enabled?
              tags = { service: service, operation: operation, error_class: error.class.name }
              BrainzLab::Flux.increment("aws.errors", tags: tags)
            end
          end
        end
      end
    end
  end
end
