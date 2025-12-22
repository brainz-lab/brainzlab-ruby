# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class << self
      def install!
        install_http! if BrainzLab.configuration.instrument_http
      end

      def install_http!
        require_relative "instrumentation/net_http"
        NetHttp.install!
      end
    end
  end
end
