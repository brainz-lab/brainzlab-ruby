# Brainz Lab SDK for Ruby

Official Ruby SDK for [Brainz Lab](https://brainzlab.ai) - structured logging with Recall and error tracking with Reflex.

## Installation

Add to your Gemfile:

```ruby
gem 'brainzlab-sdk'
```

Then run:

```bash
bundle install
```

## Quick Start

### Configuration

```ruby
# config/initializers/brainzlab.rb
BrainzLab.configure do |config|
  config.secret_key = ENV['BRAINZLAB_SECRET_KEY']
  config.environment = Rails.env
  config.service = 'my-app'
end
```

### Logging with Recall

```ruby
BrainzLab::Recall.info("User signed up", user_id: user.id)
BrainzLab::Recall.error("Payment failed", error: e.message, amount: order.total)
```

### Error Tracking with Reflex

```ruby
begin
  risky_operation
rescue => e
  BrainzLab::Reflex.capture(e, user_id: current_user.id)
end
```

## Rails Integration

The SDK automatically integrates with Rails:

- Captures request context (request_id, path, method)
- Reports unhandled exceptions to Reflex
- Adds user context when `current_user` is available

### Setting User Context

```ruby
class ApplicationController < ActionController::Base
  before_action :set_brainzlab_user

  private

  def set_brainzlab_user
    if current_user
      BrainzLab.set_user(
        id: current_user.id,
        email: current_user.email
      )
    end
  end
end
```

## Documentation

Full documentation available at [docs.brainzlab.ai](https://docs.brainzlab.ai/sdk/ruby/installation)

## License

MIT License - see [LICENSE](LICENSE) for details.
