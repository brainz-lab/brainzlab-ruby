# frozen_string_literal: true

require_relative "brainzlab/version"
require_relative "brainzlab/configuration"
require_relative "brainzlab/context"
require_relative "brainzlab/recall"
require_relative "brainzlab/reflex"
require_relative "brainzlab/pulse"
require_relative "brainzlab/flux"
require_relative "brainzlab/instrumentation"

module BrainzLab
  class << self
    def configure
      yield(configuration) if block_given?
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def reset_configuration!
      @configuration = Configuration.new
      Recall.reset!
      Reflex.reset!
      Pulse.reset!
      Flux.reset!
    end

    # Context management
    def set_user(id: nil, email: nil, name: nil, **extra)
      Context.current.set_user(id: id, email: email, name: name, **extra)
    end

    def set_context(**data)
      Context.current.set_context(**data)
    end

    def set_tags(**data)
      Context.current.set_tags(**data)
    end

    def with_context(**data, &block)
      Context.current.with_context(**data, &block)
    end

    def clear_context!
      Context.clear!
    end

    # Breadcrumb helpers
    def add_breadcrumb(message, category: "default", level: :info, data: nil)
      Reflex.add_breadcrumb(message, category: category, level: level, data: data)
    end

    def clear_breadcrumbs!
      Reflex.clear_breadcrumbs!
    end

    # Create a logger that can replace Rails.logger
    # @param broadcast_to [Logger] Optional logger to also send logs to (e.g., original Rails.logger)
    # @return [BrainzLab::Recall::Logger]
    def logger(broadcast_to: nil)
      Recall::Logger.new(nil, broadcast_to: broadcast_to)
    end

    # Debug logging helper
    def debug_log(message)
      configuration.debug_log(message)
    end

    # Check if debug mode is enabled
    def debug?
      configuration.debug?
    end

    # Health check - verifies connectivity to all enabled services
    # @return [Hash] Status of each service
    def health_check
      results = { status: 'ok', services: {} }

      # Check Recall
      if configuration.recall_enabled
        results[:services][:recall] = check_service_health(
          url: configuration.recall_url,
          name: 'Recall'
        )
      end

      # Check Reflex
      if configuration.reflex_enabled
        results[:services][:reflex] = check_service_health(
          url: configuration.reflex_url,
          name: 'Reflex'
        )
      end

      # Check Pulse
      if configuration.pulse_enabled
        results[:services][:pulse] = check_service_health(
          url: configuration.pulse_url,
          name: 'Pulse'
        )
      end

      # Check Flux
      if configuration.flux_enabled
        results[:services][:flux] = check_service_health(
          url: configuration.flux_url,
          name: 'Flux'
        )
      end

      # Overall status
      has_failure = results[:services].values.any? { |s| s[:status] == 'error' }
      results[:status] = has_failure ? 'degraded' : 'ok'

      results
    end

    private

    def check_service_health(url:, name:)
      require 'net/http'
      require 'uri'

      uri = URI.parse("#{url}/up")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 5

      response = http.get(uri.request_uri)

      if response.is_a?(Net::HTTPSuccess)
        { status: 'ok', latency_ms: 0 }
      else
        { status: 'error', message: "HTTP #{response.code}" }
      end
    rescue StandardError => e
      { status: 'error', message: e.message }
    end
  end
end

# Auto-load Rails integration if Rails is available
if defined?(Rails::Railtie)
  require_relative "brainzlab/rails/railtie"
end
