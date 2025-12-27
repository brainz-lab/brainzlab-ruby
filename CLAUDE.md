# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project: BrainzLab Ruby SDK

Official Ruby SDK gem for all BrainzLab products - the unified client for Rails applications.

**Gem**: brainzlab (on RubyGems.org)

**GitHub**: brainz-lab/brainzlab-ruby

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      BRAINZLAB SDK (Ruby Gem)                    │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │    Recall    │  │    Reflex    │  │     Pulse    │           │
│  │  (Logging)   │  │  (Errors)    │  │    (APM)     │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                           │                                      │
│                           ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                     Transport Layer                          ││
│  │   Buffering • Batching • Retry • Context Propagation        ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
              ┌───────────────────────────────┐
              │   BrainzLab Services (APIs)   │
              │   Recall • Reflex • Pulse     │
              └───────────────────────────────┘
```

## Directory Structure

```
lib/
├── brainzlab.rb              # Main entry point & configuration
├── brainzlab-sdk.rb          # Gem loader
└── brainzlab/
    ├── version.rb
    ├── configuration.rb
    ├── recall/               # Logging client
    │   ├── client.rb
    │   ├── logger.rb
    │   └── buffer.rb
    ├── reflex/               # Error tracking client
    │   ├── client.rb
    │   ├── capture.rb
    │   └── breadcrumbs.rb
    ├── pulse/                # APM client
    │   ├── client.rb
    │   ├── tracer.rb
    │   └── spans.rb
    ├── middleware/           # Rails middleware
    │   ├── rack.rb
    │   └── sidekiq.rb
    ├── instrumentation/      # Auto-instrumentation
    │   ├── rails.rb
    │   ├── active_record.rb
    │   └── http.rb
    └── transport/            # HTTP layer
        ├── client.rb
        └── buffer.rb
```

## Common Commands

```bash
# Development
bundle install
bundle exec rake spec          # Run tests

# Build gem
gem build brainzlab.gemspec

# Install locally
gem install brainzlab-*.gem

# Console testing
bundle exec irb -r brainzlab
```

## Key Modules

### BrainzLab::Recall (Logging)
```ruby
BrainzLab::Recall.info("Message", key: "value")
BrainzLab::Recall.error("Error occurred", error: e.message)
```

### BrainzLab::Reflex (Error Tracking)
```ruby
BrainzLab::Reflex.capture(exception)
BrainzLab::Reflex.capture(exception, context: { user_id: 123 })
```

### BrainzLab::Pulse (APM)
```ruby
BrainzLab::Pulse.trace("operation.name") do
  # Your code here
end
```

## Configuration

```ruby
BrainzLab.configure do |config|
  config.secret_key = ENV['BRAINZLAB_SECRET_KEY']
  config.environment = Rails.env
  config.service = 'my-app'

  # Enable products
  config.recall_enabled = true
  config.reflex_enabled = true
  config.pulse_enabled = true

  # Auto-provisioning
  config.recall_auto_provision = true
  config.reflex_auto_provision = true
  config.pulse_auto_provision = true
end
```

## Middleware

Rails middleware auto-installed via Railtie:
- Request context (request_id, session_id)
- Error capture for unhandled exceptions
- APM tracing for requests

Sidekiq middleware:
- Job context propagation
- Error capture for failed jobs
- APM tracing for jobs

## SDK Clients

Each product has a dedicated client:
- `BrainzLab::Recall::Client` - Logging
- `BrainzLab::Reflex::Client` - Errors
- `BrainzLab::Pulse::Client` - APM

## Transport Features

- **Buffering**: Batches requests for efficiency
- **Retry**: Automatic retry with exponential backoff
- **Async**: Non-blocking background flushing
- **Context**: Automatic propagation of trace context

## Testing

```bash
# Run all specs
bundle exec rspec

# Run specific spec
bundle exec rspec spec/brainzlab/recall_spec.rb

# Run with coverage
COVERAGE=true bundle exec rspec
```

## Publishing

```bash
# Login to RubyGems
gem signin

# Build and push
gem build brainzlab.gemspec
gem push brainzlab-*.gem
```

## Future Language SDKs

See sdk-spec.md for the multi-language roadmap:
1. Ruby (current)
2. Elixir
3. Node.js/TypeScript
4. Python
5. Go
6. Java/Kotlin
7. PHP
8. Rust
9. OpenTelemetry (universal)
