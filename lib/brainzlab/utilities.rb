# frozen_string_literal: true

require_relative 'utilities/rate_limiter'
require_relative 'utilities/circuit_breaker'
require_relative 'utilities/health_check'
require_relative 'utilities/log_formatter'

module BrainzLab
  module Utilities
    # All utilities are auto-loaded from their respective files
    # Access them via:
    #   BrainzLab::Utilities::RateLimiter
    #   BrainzLab::Utilities::CircuitBreaker
    #   BrainzLab::Utilities::HealthCheck
    #   BrainzLab::Utilities::LogFormatter
  end
end
