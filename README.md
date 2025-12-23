# BrainzLab Ruby SDK

[![Gem Version](https://badge.fury.io/rb/brainzlab.svg)](https://rubygems.org/gems/brainzlab)
[![CI](https://github.com/brainz-lab/brainzlab-ruby/actions/workflows/ci.yml/badge.svg)](https://github.com/brainz-lab/brainzlab-ruby/actions/workflows/ci.yml)
[![Docs](https://img.shields.io/badge/docs-brainzlab.ai-orange)](https://docs.brainzlab.ai/sdk/ruby/installation)
[![License](https://img.shields.io/badge/license-Ossassy-blue.svg)](LICENSE)

Official Ruby SDK for [BrainzLab](https://brainzlab.ai) - the complete observability platform.

- **Recall** - Structured logging
- **Reflex** - Error tracking
- **Pulse** - APM & distributed tracing

## Installation

### From RubyGems (recommended)

Add to your Gemfile:

```ruby
gem 'brainzlab'
```

Then run:

```bash
bundle install
```

### From GitHub Packages

Add the GitHub Packages source to your Gemfile:

```ruby
source "https://rubygems.pkg.github.com/brainz-lab" do
  gem 'brainzlab'
end
```

Configure Bundler with your GitHub token:

```bash
bundle config set --global rubygems.pkg.github.com USERNAME:TOKEN
```

## Quick Start

### Configuration

```ruby
# config/initializers/brainzlab.rb
BrainzLab.configure do |config|
  # Authentication (required)
  config.secret_key = ENV['BRAINZLAB_SECRET_KEY']

  # Environment
  config.environment = Rails.env
  config.service = 'my-app'

  # Enable/disable products
  config.recall_enabled = true   # Logging
  config.reflex_enabled = true   # Error tracking
  config.pulse_enabled = true    # APM

  # Auto-provisioning (creates projects automatically)
  config.recall_auto_provision = true
  config.reflex_auto_provision = true
  config.pulse_auto_provision = true
end
```

## Recall - Structured Logging

```ruby
# Log levels
BrainzLab::Recall.debug("Debug message", details: "...")
BrainzLab::Recall.info("User signed up", user_id: user.id)
BrainzLab::Recall.warn("Rate limit approaching", current: 95, limit: 100)
BrainzLab::Recall.error("Payment failed", error: e.message, amount: 99.99)
BrainzLab::Recall.fatal("Database connection lost")

# With context
BrainzLab::Recall.info("Order created",
  order_id: order.id,
  user_id: user.id,
  total: order.total,
  items: order.items.count
)
```

### Configuration Options

```ruby
config.recall_min_level = :info        # Minimum log level (:debug, :info, :warn, :error, :fatal)
config.recall_buffer_size = 50         # Batch size before flush
config.recall_flush_interval = 5       # Seconds between flushes
```

## Reflex - Error Tracking

```ruby
# Capture exceptions
begin
  risky_operation
rescue => e
  BrainzLab::Reflex.capture(e,
    user_id: current_user.id,
    order_id: order.id
  )
end

# Add breadcrumbs for context
BrainzLab::Reflex.add_breadcrumb("User clicked checkout",
  category: "ui.click",
  data: { button: "checkout" }
)

# Set user context
BrainzLab::Reflex.set_user(
  id: user.id,
  email: user.email,
  plan: user.plan
)

# Add tags
BrainzLab::Reflex.set_tags(
  environment: "production",
  region: "us-east-1"
)
```

### Configuration Options

```ruby
config.reflex_excluded_exceptions = ['ActiveRecord::RecordNotFound']
config.reflex_sample_rate = 1.0        # 1.0 = 100%, 0.5 = 50%
config.reflex_before_send = ->(event) {
  # Modify or filter events
  event[:tags][:custom] = 'value'
  event  # Return nil to drop the event
}
```

## Pulse - APM & Distributed Tracing

Pulse automatically instruments your application to track performance.

### Automatic Instrumentation

The SDK automatically instruments:

| Library | Description |
|---------|-------------|
| Rails/Rack | Request tracing with breakdown |
| Active Record | SQL queries with timing |
| Net::HTTP | Outbound HTTP calls |
| Faraday | HTTP client requests |
| HTTParty | HTTP client requests |
| Redis | Redis commands |
| Sidekiq | Background job processing |
| Delayed::Job | Background job processing |
| GraphQL | Query and field resolution |
| Grape | API endpoint tracing |
| MongoDB | Database operations |
| Elasticsearch | Search operations |
| ActionMailer | Email delivery |

### Configuration Options

```ruby
# Enable/disable specific instrumentations
config.instrument_http = true           # Net::HTTP, Faraday, HTTParty
config.instrument_active_record = true  # SQL queries
config.instrument_redis = true          # Redis commands
config.instrument_sidekiq = true        # Sidekiq jobs
config.instrument_graphql = true        # GraphQL queries
config.instrument_mongodb = true        # MongoDB operations
config.instrument_elasticsearch = true  # Elasticsearch queries
config.instrument_action_mailer = true  # Email delivery
config.instrument_delayed_job = true    # Delayed::Job
config.instrument_grape = true          # Grape API

# Filtering
config.http_ignore_hosts = ['localhost', '127.0.0.1']
config.redis_ignore_commands = ['ping', 'info']
config.pulse_excluded_paths = ['/health', '/ping', '/up', '/assets']
config.pulse_sample_rate = 1.0          # 1.0 = 100%
```

### Distributed Tracing

Pulse supports distributed tracing across services using W3C Trace Context and B3 propagation.

```ruby
# Extracting trace context from incoming requests (automatic in Rails)
context = BrainzLab::Pulse.extract!(request.headers)

# Injecting trace context into outgoing requests (automatic with instrumentation)
BrainzLab::Pulse.inject!(headers)
```

### Custom Spans

```ruby
BrainzLab::Pulse.trace("process_payment", kind: "payment") do |span|
  span[:data] = { amount: 99.99, currency: "USD" }
  process_payment(order)
end
```

## Rails Integration

The SDK automatically integrates with Rails when loaded:

- Request context (request_id, path, method, params)
- Exception reporting to Reflex
- Performance tracing with Pulse
- User context from `current_user`

### Setting User Context

```ruby
class ApplicationController < ActionController::Base
  before_action :set_brainzlab_context

  private

  def set_brainzlab_context
    if current_user
      BrainzLab.set_user(
        id: current_user.id,
        email: current_user.email,
        name: current_user.name
      )
    end
  end
end
```

## Sidekiq Integration

For Sidekiq, the SDK automatically:

- Traces job execution with queue wait time
- Propagates trace context between web and worker
- Captures job failures to Reflex

```ruby
# config/initializers/sidekiq.rb
# Instrumentation is automatic, but you can configure:

BrainzLab.configure do |config|
  config.instrument_sidekiq = true
end
```

## Grape API Integration

For Grape APIs, you can use the middleware:

```ruby
class API < Grape::API
  use BrainzLab::Instrumentation::GrapeInstrumentation::Middleware

  # Your API endpoints...
end
```

## GraphQL Integration

For GraphQL-Ruby 2.0+, add the tracer:

```ruby
class MySchema < GraphQL::Schema
  trace_with BrainzLab::Instrumentation::GraphQLInstrumentation::Tracer

  # Your schema...
end
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `BRAINZLAB_SECRET_KEY` | API key for authentication |
| `BRAINZLAB_ENVIRONMENT` | Environment name (default: auto-detect) |
| `BRAINZLAB_SERVICE` | Service name |
| `BRAINZLAB_APP_NAME` | App name for auto-provisioning |
| `BRAINZLAB_DEBUG` | Enable debug logging (`true`/`false`) |
| `RECALL_URL` | Custom Recall endpoint |
| `REFLEX_URL` | Custom Reflex endpoint |
| `PULSE_URL` | Custom Pulse endpoint |

## Scrubbing Sensitive Data

The SDK automatically scrubs sensitive fields:

```ruby
config.scrub_fields = [:password, :password_confirmation, :token, :api_key, :secret]
```

## Debug Mode

Enable debug mode to see SDK activity:

```ruby
config.debug = true
# Or set BRAINZLAB_DEBUG=true
```

## Self-Hosted

For self-hosted BrainzLab installations:

```ruby
BrainzLab.configure do |config|
  config.recall_url = 'https://recall.your-domain.com'
  config.reflex_url = 'https://reflex.your-domain.com'
  config.pulse_url = 'https://pulse.your-domain.com'
end
```

## Documentation

Full documentation: [docs.brainzlab.ai](https://docs.brainzlab.ai)

- [Installation Guide](https://docs.brainzlab.ai/sdk/ruby/installation)
- [Recall (Logging)](https://docs.brainzlab.ai/sdk/ruby/recall)
- [Reflex (Errors)](https://docs.brainzlab.ai/sdk/ruby/reflex)
- [Pulse (APM)](https://docs.brainzlab.ai/sdk/ruby/pulse)

## Related

- [Recall](https://github.com/brainz-lab/recall) - Logging service
- [Reflex](https://github.com/brainz-lab/reflex) - Error tracking service
- [Pulse](https://github.com/brainz-lab/pulse) - APM service
- [Stack](https://github.com/brainz-lab/stack) - Self-hosted deployment

## License

Ossassy License - see [LICENSE](LICENSE) for details.
