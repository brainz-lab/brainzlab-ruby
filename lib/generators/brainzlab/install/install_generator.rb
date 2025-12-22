# frozen_string_literal: true

require "rails/generators/base"

module Brainzlab
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a BrainzLab initializer for your Rails application"

      class_option :key, type: :string, desc: "Your BrainzLab secret key"
      class_option :replace_logger, type: :boolean, default: false, desc: "Replace Rails.logger with BrainzLab logger"

      def copy_initializer
        template "brainzlab.rb.tt", "config/initializers/brainzlab.rb"
      end

      def show_post_install_message
        say ""
        say "BrainzLab SDK installed successfully!", :green
        say ""
        say "Next steps:"
        say "  1. Set your BRAINZLAB_SECRET_KEY environment variable"
        say "     Get your key from: https://brainzlab.ai/dashboard"
        say ""
        say "  2. Start logging:"
        say "     BrainzLab::Recall.info('Hello from BrainzLab!')"
        say ""
        if options[:replace_logger]
          say "  Rails.logger is now connected to Recall!", :yellow
        else
          say "  To send all Rails logs to Recall, add to your initializer:"
          say "     Rails.logger = BrainzLab.logger(broadcast_to: Rails.logger)"
        end
        say ""
      end

      private

      def secret_key_value
        if options[:key].present?
          %("#{options[:key]}")
        else
          'ENV["BRAINZLAB_SECRET_KEY"]'
        end
      end

      def app_name
        Rails.application.class.module_parent_name.underscore rescue "my-app"
      end
    end
  end
end
