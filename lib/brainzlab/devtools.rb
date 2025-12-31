# frozen_string_literal: true

require_relative 'devtools/data/collector'
require_relative 'devtools/middleware/asset_server'
require_relative 'devtools/middleware/database_handler'
require_relative 'devtools/middleware/error_page'
require_relative 'devtools/middleware/debug_panel'
require_relative 'devtools/renderers/error_page_renderer'
require_relative 'devtools/renderers/debug_panel_renderer'

module BrainzLab
  module DevTools
    ASSETS_PATH = File.expand_path('devtools/assets', __dir__)

    class << self
      def enabled?
        BrainzLab.configuration.devtools_enabled
      end

      def error_page_enabled?
        enabled? && BrainzLab.configuration.devtools_error_page_enabled
      end

      def debug_panel_enabled?
        enabled? && BrainzLab.configuration.devtools_debug_panel_enabled
      end

      def allowed_environment?
        allowed = BrainzLab.configuration.devtools_allowed_environments
        current = BrainzLab.configuration.environment
        allowed.include?(current)
      end

      def allowed_ip?(request_ip)
        # Skip IP checking in development - environment check is enough
        return true if BrainzLab.configuration.environment == 'development'

        return true if BrainzLab.configuration.devtools_allowed_ips.empty?

        allowed_ips = BrainzLab.configuration.devtools_allowed_ips
        return true if allowed_ips.include?(request_ip)

        # Check CIDR ranges
        allowed_ips.any? do |ip|
          if ip.include?('/')
            ip_in_cidr?(request_ip, ip)
          else
            ip == request_ip
          end
        end
      end

      def asset_path
        BrainzLab.configuration.devtools_asset_path
      end

      def panel_position
        BrainzLab.configuration.devtools_panel_position
      end

      def expand_by_default?
        BrainzLab.configuration.devtools_expand_by_default
      end

      private

      def ip_in_cidr?(ip, cidr)
        require 'ipaddr'
        IPAddr.new(cidr).include?(IPAddr.new(ip))
      rescue IPAddr::InvalidAddressError
        false
      end
    end
  end
end
