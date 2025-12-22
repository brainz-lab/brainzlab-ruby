# frozen_string_literal: true

require "spec_helper"

RSpec.describe BrainzLab::Reflex do
  before do
    BrainzLab.configure do |config|
      config.secret_key = "test_key"
      config.service = "test-service"
      config.environment = "test"
      config.reflex_url = "https://reflex.brainzlab.ai"
    end

    stub_request(:post, "https://reflex.brainzlab.ai/api/v1/errors")
      .to_return(status: 201, body: '{"id": "error_123"}')
  end

  describe ".capture" do
    it "captures an exception" do
      error = StandardError.new("Something went wrong")
      error.set_backtrace(["app/models/user.rb:42:in `save'", "app/controllers/users_controller.rb:10:in `create'"])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["error_class"] == "StandardError" &&
            body["message"] == "Something went wrong" &&
            body["backtrace"].is_a?(Array)
        }
    end

    it "includes environment context" do
      error = StandardError.new("Test error")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["environment"] == "test" &&
            body["server_name"].is_a?(String)
        }
    end

    it "includes user context" do
      BrainzLab.set_user(id: 123, email: "test@example.com", name: "Test User")

      error = StandardError.new("User error")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["user"]["id"] == "123" &&
            body["user"]["email"] == "test@example.com"
        }
    end

    it "respects excluded exceptions" do
      BrainzLab.configuration.reflex_excluded_exceptions = ["ArgumentError"]

      error = ArgumentError.new("Bad argument")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).not_to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
    end

    it "respects sample rate" do
      BrainzLab.configuration.reflex_sample_rate = 0.0

      error = StandardError.new("Sampled out")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).not_to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
    end

    it "includes breadcrumbs" do
      BrainzLab.add_breadcrumb("User clicked button", category: "ui", data: { button: "submit" })
      BrainzLab.add_breadcrumb("API request started", category: "http")

      error = StandardError.new("With breadcrumbs")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["breadcrumbs"].size == 2 &&
            body["breadcrumbs"][0]["message"] == "User clicked button"
        }
    end
  end

  describe ".capture_message" do
    it "captures a message event" do
      described_class.capture_message("Something noteworthy happened", level: :warning)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["error_class"] == "Message" &&
            body["message"] == "Something noteworthy happened" &&
            body["level"] == "warning"
        }
    end
  end

  describe ".without_capture" do
    it "disables capture within block" do
      described_class.without_capture do
        error = StandardError.new("Ignored error")
        error.set_backtrace([])
        described_class.capture(error)
      end

      expect(WebMock).not_to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
    end
  end

  describe "before_send hook" do
    it "allows modifying payload" do
      BrainzLab.configuration.reflex_before_send = ->(payload, _exception) {
        payload[:custom_field] = "added"
        payload
      }

      error = StandardError.new("Modified error")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["custom_field"] == "added"
        }
    end

    it "allows dropping event by returning nil" do
      BrainzLab.configuration.reflex_before_send = ->(_payload, _exception) { nil }

      error = StandardError.new("Dropped error")
      error.set_backtrace([])

      described_class.capture(error)

      expect(WebMock).not_to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
    end
  end

  describe "backtrace parsing" do
    it "parses Ruby backtrace format" do
      error = StandardError.new("Test")
      error.set_backtrace([
        "app/models/user.rb:42:in `save'",
        "/gems/activerecord/lib/base.rb:100:in `create'"
      ])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          frame = body["backtrace"][0]
          frame["file"] == "app/models/user.rb" &&
            frame["line"] == 42 &&
            frame["function"] == "save" &&
            frame["in_app"] == true
        }
    end

    it "marks gem frames as not in_app" do
      error = StandardError.new("Test")
      error.set_backtrace(["/gems/activerecord/lib/base.rb:100:in `create'"])

      described_class.capture(error)

      expect(WebMock).to have_requested(:post, "https://reflex.brainzlab.ai/api/v1/errors")
        .with { |req|
          body = JSON.parse(req.body)
          body["backtrace"][0]["in_app"] == false
        }
    end
  end
end
