# Brainz Lab - Multi-Language SDK Roadmap

## Strategy

**Phase 1: Ruby First (Now)**
- Complete all products with Ruby SDK
- Prove the platform works
- Build community

**Phase 2: Expand Languages (After Core Complete)**
- Add SDKs for major languages
- OpenTelemetry support for universal compatibility
- Same great experience everywhere

---

## Language Priority Order

```
PHASE 1: FOUNDATION (Current)
└── Ruby/Rails              ✅ Done - Our home turf

PHASE 2: HIGH PRIORITY (After core products complete)
├── 1. Elixir/Phoenix       ← Similar community, BEAM ecosystem
├── 2. Node.js/TypeScript   ← Huge ecosystem, full-stack Rails devs
├── 3. Python               ← Data science, Django/FastAPI
└── 4. Go                   ← Backend services, DevOps

PHASE 3: ENTERPRISE LANGUAGES
├── 5. Java/Kotlin          ← Enterprise, Spring Boot
├── 6. PHP                  ← Laravel, WordPress
└── 7. Rust                 ← Performance-critical services

PHASE 4: UNIVERSAL
└── OpenTelemetry           ← Any language, standard protocol
```

---

## Why This Order?

| Language | Why Priority | Community Overlap |
|----------|--------------|-------------------|
| **Elixir** | Phoenix devs = Rails refugees, similar philosophy | High |
| **Node.js** | Full-stack Rails devs often use Node, huge npm | High |
| **Python** | Django/FastAPI growing, data teams need observability | Medium |
| **Go** | Microservices, often paired with Rails | Medium |
| **Java** | Enterprise $$$, Spring Boot massive | Low but $$ |
| **PHP** | Laravel = "PHP Rails", WordPress plugins | Medium |
| **Rust** | Growing, performance services | Low |
| **OpenTelemetry** | Universal, any language | All |

---

## SDK Architecture (Consistent Across Languages)

### Core Components (Every SDK)

```
brainzlab-{language}/
├── recall/           # Logging
│   ├── logger
│   ├── context
│   └── buffer
├── reflex/           # Errors
│   ├── capture
│   ├── breadcrumbs
│   └── context
├── pulse/            # APM
│   ├── tracer
│   ├── spans
│   └── metrics
├── cortex/           # Feature Flags
│   ├── client
│   └── cache
├── instrumentation/  # Auto-instrumentation
│   ├── http
│   ├── database
│   └── queue
└── transport/        # HTTP client, batching
    ├── client
    └── buffer
```

### Shared API Design

```ruby
# Ruby
BrainzLab::Recall.info("message", key: "value")
BrainzLab::Reflex.capture(exception)
BrainzLab::Pulse.trace("operation") { }
BrainzLab::Cortex.enabled?(:flag)
```

```elixir
# Elixir
BrainzLab.Recall.info("message", key: "value")
BrainzLab.Reflex.capture(exception)
BrainzLab.Pulse.trace("operation", fn -> end)
BrainzLab.Cortex.enabled?(:flag)
```

```javascript
// Node.js
brainzlab.recall.info("message", { key: "value" });
brainzlab.reflex.capture(error);
brainzlab.pulse.trace("operation", () => { });
brainzlab.cortex.enabled("flag");
```

```python
# Python
brainzlab.recall.info("message", key="value")
brainzlab.reflex.capture(exception)
with brainzlab.pulse.trace("operation"):
    pass
brainzlab.cortex.enabled("flag")
```

```go
// Go
brainzlab.Recall.Info("message", brainzlab.Fields{"key": "value"})
brainzlab.Reflex.Capture(err)
brainzlab.Pulse.Trace("operation", func() { })
brainzlab.Cortex.Enabled("flag")
```

```java
// Java
BrainzLab.recall().info("message", Map.of("key", "value"));
BrainzLab.reflex().capture(exception);
BrainzLab.pulse().trace("operation", () -> { });
BrainzLab.cortex().enabled("flag");
```

```php
// PHP
BrainzLab\Recall::info("message", ["key" => "value"]);
BrainzLab\Reflex::capture($exception);
BrainzLab\Pulse::trace("operation", function() { });
BrainzLab\Cortex::enabled("flag");
```

```rust
// Rust
brainzlab::recall::info!("message", key = "value");
brainzlab::reflex::capture(&error);
brainzlab::pulse::trace("operation", || { });
brainzlab::cortex::enabled("flag");
```

---

## Language-Specific Details

### 1. Elixir SDK

```
Package: brainzlab (Hex)
Repo: github.com/brainzlab/brainzlab-elixir

Auto-instrumentation:
├── Phoenix
├── Ecto
├── Tesla/HTTPoison
├── Oban (jobs)
├── Absinthe (GraphQL)
└── Broadway (data pipelines)

Special Features:
├── Process-based context (no thread locals needed!)
├── Telemetry integration (Phoenix default)
├── LiveView error tracking
└── Distributed tracing across nodes
```

```elixir
# mix.exs
{:brainzlab, "~> 1.0"}

# config/config.exs
config :brainzlab,
  secret_key: System.get_env("BRAINZLAB_SECRET_KEY"),
  environment: Mix.env()

# Automatic Phoenix instrumentation
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  use BrainzLab.Phoenix  # Auto-instrument
end
```

### 2. Node.js SDK

```
Package: @brainzlab/sdk (npm)
Repo: github.com/brainzlab/brainzlab-node

Auto-instrumentation:
├── Express
├── Fastify
├── Koa
├── Next.js
├── Prisma/Sequelize/TypeORM
├── Axios/fetch
├── Bull/BullMQ (jobs)
└── GraphQL (Apollo, etc.)

Special Features:
├── ESM + CommonJS support
├── TypeScript definitions
├── Async context tracking (AsyncLocalStorage)
└── Serverless support (Lambda, Vercel)
```

```typescript
// npm install @brainzlab/sdk

import { BrainzLab } from '@brainzlab/sdk';

BrainzLab.init({
  secretKey: process.env.BRAINZLAB_SECRET_KEY,
  environment: process.env.NODE_ENV,
});

// Express middleware
app.use(BrainzLab.express());

// Manual usage
BrainzLab.recall.info("User signed up", { userId: user.id });
```

### 3. Python SDK

```
Package: brainzlab (PyPI)
Repo: github.com/brainzlab/brainzlab-python

Auto-instrumentation:
├── Django
├── FastAPI
├── Flask
├── SQLAlchemy
├── Celery (jobs)
├── httpx/requests
├── asyncio support
└── GraphQL (Strawberry, Graphene)

Special Features:
├── Type hints (mypy compatible)
├── Async/await support
├── Context vars for threading
└── Jupyter notebook support
```

```python
# pip install brainzlab

import brainzlab

brainzlab.init(
    secret_key=os.environ["BRAINZLAB_SECRET_KEY"],
    environment="production"
)

# Django middleware (auto)
MIDDLEWARE = [
    "brainzlab.django.BrainzLabMiddleware",
    # ...
]

# FastAPI
from brainzlab.fastapi import BrainzLabMiddleware
app.add_middleware(BrainzLabMiddleware)
```

### 4. Go SDK

```
Package: github.com/brainzlab/brainzlab-go
Repo: github.com/brainzlab/brainzlab-go

Auto-instrumentation:
├── net/http
├── Gin
├── Echo
├── Fiber
├── GORM
├── sqlx
└── go-redis

Special Features:
├── Context-based tracing
├── Goroutine-safe
├── Low allocation design
└── gRPC support
```

```go
// go get github.com/brainzlab/brainzlab-go

import "github.com/brainzlab/brainzlab-go"

func main() {
    brainzlab.Init(brainzlab.Config{
        SecretKey:   os.Getenv("BRAINZLAB_SECRET_KEY"),
        Environment: "production",
    })
    defer brainzlab.Flush()

    // Gin middleware
    r := gin.Default()
    r.Use(brainzlab.GinMiddleware())
}
```

### 5. Java SDK

```
Package: ai.brainzlab:brainzlab-sdk (Maven Central)
Repo: github.com/brainzlab/brainzlab-java

Auto-instrumentation:
├── Spring Boot
├── Spring WebFlux
├── Hibernate/JPA
├── JDBC
├── OkHttp/Apache HttpClient
├── Kafka
└── Reactor/RxJava

Special Features:
├── Java 11+ support
├── Kotlin extensions
├── Virtual threads (Java 21)
└── GraalVM native-image support
```

```java
// Maven
// <dependency>
//   <groupId>ai.brainzlab</groupId>
//   <artifactId>brainzlab-spring-boot-starter</artifactId>
// </dependency>

// application.yml
brainzlab:
  secret-key: ${BRAINZLAB_SECRET_KEY}
  environment: production

// Auto-configured with Spring Boot!
```

### 6. PHP SDK

```
Package: brainzlab/sdk (Packagist)
Repo: github.com/brainzlab/brainzlab-php

Auto-instrumentation:
├── Laravel
├── Symfony
├── WordPress
├── Doctrine
├── Guzzle
├── Laravel Horizon (jobs)
└── GraphQL (Lighthouse)

Special Features:
├── PHP 8.1+ support
├── Composer autoload
├── Laravel service provider
└── WordPress plugin
```

```php
// composer require brainzlab/sdk

// Laravel - config/brainzlab.php
return [
    'secret_key' => env('BRAINZLAB_SECRET_KEY'),
    'environment' => env('APP_ENV'),
];

// Auto-registered via Laravel package discovery
```

### 7. Rust SDK

```
Package: brainzlab (crates.io)
Repo: github.com/brainzlab/brainzlab-rust

Auto-instrumentation:
├── Actix-web
├── Axum
├── Rocket
├── SQLx
├── Diesel
├── reqwest
└── Tokio tracing integration

Special Features:
├── Zero-cost abstractions
├── Async runtime support
├── tracing crate integration
└── WASM support (for edge functions)
```

```rust
// Cargo.toml
// [dependencies]
// brainzlab = "1.0"

use brainzlab::BrainzLab;

#[tokio::main]
async fn main() {
    BrainzLab::init(Config {
        secret_key: std::env::var("BRAINZLAB_SECRET_KEY").unwrap(),
        environment: "production".into(),
    });

    // Axum integration
    let app = Router::new()
        .layer(brainzlab::axum::layer());
}
```

---

## OpenTelemetry Strategy

### Why OpenTelemetry?

```
1. UNIVERSAL PROTOCOL
   Any language with OTLP support can send to Brainz Lab

2. EXISTING INSTRUMENTATION
   Don't reinvent the wheel - use existing OTel instrumentation

3. VENDOR NEUTRAL
   Users aren't locked in - they chose us because we're better

4. ENTERPRISE
   Many enterprises already use OTel - easy adoption
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        OPENTELEMETRY SUPPORT                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ANY LANGUAGE                    BRAINZ LAB                                │
│   ┌──────────────┐               ┌──────────────┐                          │
│   │  OTel SDK    │───OTLP/HTTP──▶│  Collector   │                          │
│   │  (traces,    │               │  Endpoint    │                          │
│   │   metrics,   │               │              │                          │
│   │   logs)      │               │ /v1/traces   │                          │
│   └──────────────┘               │ /v1/metrics  │                          │
│                                  │ /v1/logs     │                          │
│                                  └──────┬───────┘                          │
│                                         │                                   │
│                                         ▼                                   │
│                          ┌──────────────────────────────┐                  │
│                          │    Brainz Lab Products       │                  │
│                          │                              │                  │
│                          │  Traces → Pulse              │                  │
│                          │  Logs → Recall               │                  │
│                          │  Errors → Reflex             │                  │
│                          │  Metrics → Pulse             │                  │
│                          │                              │                  │
│                          └──────────────────────────────┘                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### OTLP Endpoint

```yaml
# User's OTel Collector config
exporters:
  otlphttp:
    endpoint: https://otel.brainzlab.ai
    headers:
      Authorization: "Bearer ${BRAINZLAB_SECRET_KEY}"

service:
  pipelines:
    traces:
      exporters: [otlphttp]
    logs:
      exporters: [otlphttp]
    metrics:
      exporters: [otlphttp]
```

### Direct OTLP (No Collector)

```ruby
# Ruby with OTel
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
      OpenTelemetry::Exporter::OTLP::Exporter.new(
        endpoint: 'https://otel.brainzlab.ai/v1/traces',
        headers: { 'Authorization' => "Bearer #{ENV['BRAINZLAB_SECRET_KEY']}" }
      )
    )
  )
end
```

```python
# Python with OTel
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

exporter = OTLPSpanExporter(
    endpoint="https://otel.brainzlab.ai/v1/traces",
    headers={"Authorization": f"Bearer {os.environ['BRAINZLAB_SECRET_KEY']}"}
)
```

### OTel vs Native SDK

| Feature | Native SDK | OpenTelemetry |
|---------|------------|---------------|
| Setup complexity | Simpler | More config |
| Auto-instrumentation | Built-in | Separate packages |
| Feature flags (Cortex) | ✅ | ❌ (no OTel standard) |
| MCP integration | ✅ | ✅ (via API) |
| Custom attributes | Easier | Standard but verbose |
| Performance | Optimized | Good |

**Recommendation:** Use native SDK when available, OTel for unsupported languages.

---

## MCP Servers (Per Language)

Each language gets its own MCP server package:

```
npm:
├── @brainzlab/mcp-recall
├── @brainzlab/mcp-reflex
├── @brainzlab/mcp-pulse
├── @brainzlab/mcp-cortex
├── @brainzlab/mcp-signal
└── @brainzlab/mcp-all      ← All in one

# Why npm? MCP standard uses Node.js
# All languages use same MCP servers (they talk to our API)
```

---

## Timeline

```
CURRENT: Ruby SDK + Core Products
         ├── Recall ✅
         ├── Reflex ✅
         ├── Pulse ✅
         └── SDK ✅

NEXT 3 MONTHS: Complete Core
         ├── Platform (auth/billing)
         ├── Signal (alerts)
         ├── Cortex (flags)
         └── Synapse MVP

MONTH 4-5: Elixir + Node.js
         ├── Elixir SDK
         ├── Node.js SDK
         └── OpenTelemetry endpoint

MONTH 6-7: Python + Go
         ├── Python SDK
         └── Go SDK

MONTH 8-9: Enterprise Languages
         ├── Java SDK
         ├── PHP SDK
         └── Rust SDK

ONGOING: 
         ├── Language-specific improvements
         ├── Framework integrations
         └── Community contributions
```

---

## Open Source Strategy (Multi-Language)

All SDKs will be open source (OSSASY):

```
github.com/brainzlab/
├── brainzlab-ruby          ← Current
├── brainzlab-elixir        ← Month 4
├── brainzlab-node          ← Month 4
├── brainzlab-python        ← Month 6
├── brainzlab-go            ← Month 6
├── brainzlab-java          ← Month 8
├── brainzlab-php           ← Month 8
├── brainzlab-rust          ← Month 9
└── brainzlab-otel          ← OTel examples
```

### Package Registries

| Language | Registry | Package Name |
|----------|----------|--------------|
| Ruby | RubyGems | `brainzlab` |
| Elixir | Hex | `brainzlab` |
| Node.js | npm | `@brainzlab/sdk` |
| Python | PyPI | `brainzlab` |
| Go | GitHub | `github.com/brainzlab/brainzlab-go` |
| Java | Maven | `ai.brainzlab:brainzlab-sdk` |
| PHP | Packagist | `brainzlab/sdk` |
| Rust | crates.io | `brainzlab` |

---

## Summary

### Phase 1 (Now): Ruby Only
- Complete all products
- Prove the platform

### Phase 2 (Month 4-5): High Priority
- Elixir (similar community)
- Node.js (huge ecosystem)
- OpenTelemetry endpoint

### Phase 3 (Month 6-7): Growth
- Python (Django/FastAPI)
- Go (microservices)

### Phase 4 (Month 8-9): Enterprise
- Java (Spring Boot)
- PHP (Laravel)
- Rust (performance)

### Always: OpenTelemetry
- Universal fallback
- Any language support
- Vendor neutral

---

*Multi-language SDK ready when core is complete! 🌍*
