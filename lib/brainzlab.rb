# frozen_string_literal: true

require_relative "brainzlab/version"
require_relative "brainzlab/configuration"
require_relative "brainzlab/context"
require_relative "brainzlab/recall"
require_relative "brainzlab/reflex"
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
  end
end

# Auto-load Rails integration if Rails is available
if defined?(Rails::Railtie)
  require_relative "brainzlab/rails/railtie"
end
