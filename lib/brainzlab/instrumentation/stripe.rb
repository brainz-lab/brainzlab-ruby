# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module StripeInstrumentation
      class << self
        def install!
          return unless defined?(::Stripe)

          install_instrumentation!

          BrainzLab.debug_log("[Instrumentation] Stripe instrumentation installed")
        end

        private

        def install_instrumentation!
          # Stripe uses a request callback system
          if ::Stripe.respond_to?(:add_instrumentation)
            ::Stripe.add_instrumentation do |event|
              track_event(event)
            end
          else
            # Fallback: monkey-patch the API resource
            install_api_resource_patch!
          end
        end

        def install_api_resource_patch!
          return unless defined?(::Stripe::StripeClient)
          return unless ::Stripe::StripeClient.respond_to?(:execute_request)

          ::Stripe::StripeClient.class_eval do
            class << self
              alias_method :original_execute_request, :execute_request

              def execute_request(method, path, api_base: nil, api_key: nil, headers: {}, params: {}, usage: [])
                started_at = Time.now
                resource = extract_resource(path)

                begin
                  response = original_execute_request(
                    method, path,
                    api_base: api_base,
                    api_key: api_key,
                    headers: headers,
                    params: params,
                    usage: usage
                  )

                  BrainzLab::Instrumentation::StripeInstrumentation.track_success(
                    method, resource, path, started_at, response
                  )

                  response
                rescue StandardError => e
                  BrainzLab::Instrumentation::StripeInstrumentation.track_error(
                    method, resource, path, started_at, e
                  )
                  raise
                end
              end

              def extract_resource(path)
                # /v1/customers/cus_xxx -> customers
                parts = path.to_s.split("/").reject(&:empty?)
                parts[1] || "unknown"
              end
            end
          end
        end

        def track_event(event)
          duration_ms = (event[:duration] * 1000).round(2) if event[:duration]
          method = event[:method].to_s.upcase
          resource = event[:path].to_s.split("/")[2] || "unknown"

          BrainzLab::Reflex.add_breadcrumb(
            "Stripe #{method} #{resource}",
            category: "payment",
            level: event[:error] ? :error : :info,
            data: {
              method: method,
              resource: resource,
              status: event[:http_status],
              duration_ms: duration_ms,
              request_id: event[:request_id]
            }
          )

          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { method: method, resource: resource }
            BrainzLab::Flux.distribution("stripe.duration_ms", duration_ms, tags: tags) if duration_ms
            BrainzLab::Flux.increment("stripe.requests", tags: tags)

            if event[:error]
              BrainzLab::Flux.increment("stripe.errors", tags: tags.merge(error_type: event[:error_type]))
            end
          end
        end
      end

      def self.track_success(method, resource, path, started_at, response)
        duration_ms = ((Time.now - started_at) * 1000).round(2)

        BrainzLab::Reflex.add_breadcrumb(
          "Stripe #{method.to_s.upcase} #{resource}",
          category: "payment",
          level: :info,
          data: {
            method: method.to_s.upcase,
            resource: resource,
            path: path,
            duration_ms: duration_ms
          }
        )

        if BrainzLab.configuration.flux_effectively_enabled?
          tags = { method: method.to_s.upcase, resource: resource }
          BrainzLab::Flux.distribution("stripe.duration_ms", duration_ms, tags: tags)
          BrainzLab::Flux.increment("stripe.requests", tags: tags)
        end
      end

      def self.track_error(method, resource, path, started_at, error)
        duration_ms = ((Time.now - started_at) * 1000).round(2)
        error_type = case error
                     when Stripe::CardError then "card_error"
                     when Stripe::RateLimitError then "rate_limit"
                     when Stripe::InvalidRequestError then "invalid_request"
                     when Stripe::AuthenticationError then "authentication"
                     when Stripe::APIConnectionError then "connection"
                     when Stripe::StripeError then "stripe_error"
                     else "unknown"
                     end

        BrainzLab::Reflex.add_breadcrumb(
          "Stripe #{method.to_s.upcase} #{resource} failed: #{error.message}",
          category: "payment",
          level: :error,
          data: {
            method: method.to_s.upcase,
            resource: resource,
            error_type: error_type,
            error: error.class.name
          }
        )

        if BrainzLab.configuration.flux_effectively_enabled?
          tags = { method: method.to_s.upcase, resource: resource, error_type: error_type }
          BrainzLab::Flux.increment("stripe.errors", tags: tags)
        end

        # Capture with Reflex (but filter sensitive data)
        if BrainzLab.configuration.reflex_effectively_enabled?
          BrainzLab::Reflex.capture(error,
            tags: { source: "stripe", resource: resource },
            extra: { error_type: error_type }
          )
        end
      end
    end
  end
end
