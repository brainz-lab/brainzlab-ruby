# frozen_string_literal: true

require 'rails/generators/base'

module Brainzlab
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      desc 'Creates a BrainzLab initializer for your Rails application'

      class_option :key, type: :string, desc: 'Your BrainzLab secret key'
      class_option :replace_logger, type: :boolean, default: false, desc: 'Replace Rails.logger with BrainzLab logger'

      def copy_initializer
        template 'brainzlab.rb.tt', 'config/initializers/brainzlab.rb'
      end

      def show_post_install_message
        say ''
        say 'BrainzLab SDK installed successfully!', :green
        say ''
        say 'Next steps:'
        say '  1. Set your environment variables:'
        say '     BRAINZLAB_SECRET_KEY - Your API key from https://brainzlab.ai/dashboard'
        say ''
        say '     Or for auto-provisioning:'
        say '     RECALL_MASTER_KEY - Master key for Recall auto-provisioning'
        say '     REFLEX_MASTER_KEY - Master key for Reflex auto-provisioning'
        say ''
        say '  2. Start logging:'
        say "     BrainzLab::Recall.info('Hello from BrainzLab!')"
        say ''
        say '  3. Capture errors (automatic with Rails, or manual):'
        say '     BrainzLab::Reflex.capture(exception)'
        say ''
        if options[:replace_logger]
          say '  Rails.logger is now connected to Recall!', :yellow
        else
          say '  To send all Rails logs to Recall, add to your initializer:'
          say '     Rails.logger = BrainzLab.logger(broadcast_to: Rails.logger)'
        end
        say ''
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
        Rails.application.class.module_parent_name.underscore
      rescue StandardError
        'my-app'
      end
    end
  end
end
