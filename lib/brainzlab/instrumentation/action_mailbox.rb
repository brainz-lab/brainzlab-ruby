# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActionMailbox
      # Thresholds for slow processing (in milliseconds)
      SLOW_PROCESSING_THRESHOLD = 1000    # 1 second
      VERY_SLOW_PROCESSING_THRESHOLD = 5000  # 5 seconds

      class << self
        def install!
          return unless defined?(::ActionMailbox)
          return if @installed

          install_process_subscriber!

          @installed = true
          BrainzLab.debug_log('ActionMailbox instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # process.action_mailbox
        # Fired when an inbound email is processed
        # ============================================
        def install_process_subscriber!
          ActiveSupport::Notifications.subscribe('process.action_mailbox') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_process(event)
          end
        end

        def handle_process(event)
          payload = event.payload
          duration = event.duration.round(2)

          mailbox = payload[:mailbox]
          inbound_email = payload[:inbound_email]

          mailbox_class = mailbox.is_a?(Class) ? mailbox.name : mailbox.class.name
          email_id = inbound_email&.id
          email_status = inbound_email&.status
          message_id = inbound_email&.message_id

          # Extract sender/recipient info if available
          from = extract_from(inbound_email)
          to = extract_to(inbound_email)
          subject = extract_subject(inbound_email)

          # Determine level based on duration
          level = case duration
                  when 0...SLOW_PROCESSING_THRESHOLD then :info
                  when SLOW_PROCESSING_THRESHOLD...VERY_SLOW_PROCESSING_THRESHOLD then :warning
                  else :error
                  end

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Mailbox process: #{mailbox_class} (#{duration}ms)",
              category: 'mailbox.process',
              level: level,
              data: {
                mailbox: mailbox_class,
                email_id: email_id,
                status: email_status,
                message_id: truncate(message_id),
                from: truncate(from),
                subject: truncate(subject, 100),
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_process_span(event, mailbox_class, email_id, duration, email_status, from, to, subject)

          # Log to Recall
          log_email_processing(mailbox_class, email_id, email_status, duration, from, to, subject)
        rescue StandardError => e
          BrainzLab.debug_log("ActionMailbox process instrumentation failed: #{e.message}")
        end

        # ============================================
        # Span Recording
        # ============================================
        def record_process_span(event, mailbox_class, email_id, duration, status, from, to, subject)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "mailbox.process.#{mailbox_class.underscore}",
            kind: 'mailbox',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: status == 'bounced' || status == 'failed',
            data: {
              'mailbox.class' => mailbox_class,
              'mailbox.email_id' => email_id,
              'mailbox.status' => status,
              'mailbox.from' => truncate(from),
              'mailbox.to' => truncate(to),
              'mailbox.subject' => truncate(subject, 100)
            }.compact
          }

          tracer.current_spans << span_data
        end

        # ============================================
        # Logging
        # ============================================
        def log_email_processing(mailbox_class, email_id, status, duration, from, to, subject)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          # Determine log level based on status and duration
          if status == 'bounced' || status == 'failed'
            BrainzLab::Recall.error(
              "Mailbox processing failed: #{mailbox_class}",
              mailbox: mailbox_class,
              email_id: email_id,
              status: status,
              from: from,
              to: to,
              subject: truncate(subject, 200),
              duration_ms: duration
            )
          elsif duration >= SLOW_PROCESSING_THRESHOLD
            level = duration >= VERY_SLOW_PROCESSING_THRESHOLD ? :error : :warn
            BrainzLab::Recall.send(
              level,
              "Slow mailbox processing: #{mailbox_class} (#{duration}ms)",
              mailbox: mailbox_class,
              email_id: email_id,
              status: status,
              duration_ms: duration,
              threshold_exceeded: duration >= VERY_SLOW_PROCESSING_THRESHOLD ? 'critical' : 'warning'
            )
          end
        end

        # ============================================
        # Helper Methods
        # ============================================
        def extract_from(inbound_email)
          return nil unless inbound_email

          if inbound_email.respond_to?(:mail) && inbound_email.mail.respond_to?(:from)
            Array(inbound_email.mail.from).first
          end
        rescue StandardError
          nil
        end

        def extract_to(inbound_email)
          return nil unless inbound_email

          if inbound_email.respond_to?(:mail) && inbound_email.mail.respond_to?(:to)
            Array(inbound_email.mail.to).first
          end
        rescue StandardError
          nil
        end

        def extract_subject(inbound_email)
          return nil unless inbound_email

          if inbound_email.respond_to?(:mail) && inbound_email.mail.respond_to?(:subject)
            inbound_email.mail.subject
          end
        rescue StandardError
          nil
        end

        def truncate(value, max_length = 200)
          return nil unless value

          str = value.to_s
          if str.length > max_length
            "#{str[0, max_length - 3]}..."
          else
            str
          end
        end
      end
    end
  end
end
