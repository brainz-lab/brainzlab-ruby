# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module ActionMailerInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::ActionMailer::Base)
          return if @installed

          # Subscribe to deliver notification
          ActiveSupport::Notifications.subscribe('deliver.action_mailer') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_delivery(event)
          end

          # Subscribe to process notification (when mail is being prepared)
          ActiveSupport::Notifications.subscribe('process.action_mailer') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_process(event)
          end

          @installed = true
          BrainzLab.debug_log('ActionMailer instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def record_delivery(event)
          payload = event.payload
          mailer = payload[:mailer]
          message_id = payload[:message_id]
          duration_ms = event.duration.round(2)

          # Get mail details
          mail = payload[:mail]
          to = sanitize_recipients(mail&.to)
          subject = mail&.subject
          delivery_method = payload[:perform_deliveries] ? 'delivered' : 'skipped'

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Mail #{delivery_method}: #{mailer}",
              category: 'mailer.deliver',
              level: :info,
              data: {
                mailer: mailer,
                to: to,
                subject: truncate_subject(subject),
                message_id: message_id,
                duration_ms: duration_ms
              }.compact
            )
          end

          # Record span for Pulse
          record_span(
            name: "Mail deliver #{mailer}",
            kind: 'mailer',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration_ms,
            data: {
              mailer: mailer,
              action: 'deliver',
              to: to,
              subject: truncate_subject(subject),
              message_id: message_id,
              delivery_method: delivery_method
            }.compact
          )

          # Log to Recall
          if BrainzLab.configuration.recall_enabled
            BrainzLab::Recall.info(
              "Mail #{delivery_method}: #{mailer} to #{to} (#{duration_ms}ms)",
              mailer: mailer,
              to: to,
              subject: truncate_subject(subject),
              message_id: message_id,
              duration_ms: duration_ms
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionMailer delivery recording failed: #{e.message}")
        end

        def record_process(event)
          payload = event.payload
          mailer = payload[:mailer]
          action = payload[:action]
          duration_ms = event.duration.round(2)

          # Add breadcrumb
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Mail process: #{mailer}##{action}",
              category: 'mailer.process',
              level: :info,
              data: {
                mailer: mailer,
                action: action,
                duration_ms: duration_ms
              }
            )
          end

          # Record span for Pulse
          record_span(
            name: "Mail process #{mailer}##{action}",
            kind: 'mailer',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration_ms,
            data: {
              mailer: mailer,
              action: action
            }
          )
        rescue StandardError => e
          BrainzLab.debug_log("ActionMailer process recording failed: #{e.message}")
        end

        def record_span(name:, kind:, started_at:, ended_at:, duration_ms:, data:)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          spans << {
            span_id: SecureRandom.uuid,
            name: name,
            kind: kind,
            started_at: started_at,
            ended_at: ended_at,
            duration_ms: duration_ms,
            data: data
          }
        end

        def sanitize_recipients(recipients)
          return nil unless recipients

          case recipients
          when Array
            recipients.map { |r| mask_email(r) }.join(', ')
          else
            mask_email(recipients.to_s)
          end
        end

        def mask_email(email)
          return email unless email.include?('@')

          local, domain = email.split('@', 2)
          if local.length > 2
            "#{local[0..1]}***@#{domain}"
          else
            "***@#{domain}"
          end
        rescue StandardError
          '[email]'
        end

        def truncate_subject(subject)
          return nil unless subject

          subject.to_s[0, 100]
        end
      end
    end
  end
end
