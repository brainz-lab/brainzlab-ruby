# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2025-01-01

### Added

- **Recall** - Structured logging
  - Log levels (debug, info, warn, error, fatal)
  - Buffered batch sending
  - Auto-provisioning support
  - Rails integration

- **Reflex** - Error tracking
  - Exception capturing with context
  - Breadcrumbs support
  - User context tracking
  - Sample rate and before_send hooks
  - Custom fingerprinting
  - Auto-provisioning support

- **Pulse** - APM & Distributed Tracing
  - Request tracing with breakdown
  - Distributed tracing (W3C Trace Context + B3)
  - Auto-provisioning support

- **Instrumentation** (13 libraries)
  - Rails/Rack middleware
  - Active Record (SQL queries)
  - Net::HTTP
  - Faraday
  - HTTParty
  - Redis (v4 and v5+)
  - Sidekiq (server and client middleware)
  - Delayed::Job
  - GraphQL (query and field tracing)
  - Grape API
  - MongoDB/Mongoid
  - Elasticsearch/OpenSearch
  - ActionMailer

- **Configuration**
  - Environment variable support
  - Per-product enable/disable
  - Sensitive field scrubbing
  - Debug mode

- **Rails Integration**
  - Automatic setup via Railtie
  - Request context propagation
  - User context from current_user
