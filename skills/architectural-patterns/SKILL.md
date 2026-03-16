---
name: architectural-patterns
description: Use when reviewing code for architectural boundary violations, dependency direction errors, or layer coupling issues — covers 10 architectural patterns with invariants, violation signals, and dependency diagrams
---

# Architectural Patterns Review Skill

## Overview

Architectural patterns define the large-scale structure of a system: how major components communicate, which direction dependencies flow, and where responsibilities live. Unlike GoF design patterns (which operate at the class level), architectural patterns operate at the module, service, and system level. Code review at this level asks: "Are the boundaries intact? Are dependencies flowing the right direction? Is this component doing work that belongs to a different layer?"

## When to Use

- Reviewing a PR that adds a new layer dependency or import
- Evaluating whether a new service or module belongs where the author placed it
- Diagnosing why a codebase is hard to test or change despite "clean" individual classes
- Assessing whether the team's stated architecture matches the actual code

## Quick Reference

| Pattern | Core Invariant | Key Violation Signal |
|---------|---------------|---------------------|
| MVC | Model never imports View | View contains business logic; fat Controller |
| MVP | View is passive; Presenter mediates | View makes decisions; Presenter imports View type |
| MVVM | ViewModel does not know View | ViewModel imports UI framework types |
| Layered | Dependencies flow downward only | Data layer imports Presentation types |
| Clean Architecture | Inner circles never depend on outer circles | Entity imports from framework layer |
| Hexagonal | Domain has zero external dependencies | Domain imports HTTP, ORM, or DB libraries |
| Event-Driven | Producers don't know consumers | Producer awaits consumer response synchronously |
| Microservices | Each service owns its data | Shared database across services |
| Repository | Business logic doesn't know storage details | Service builds raw SQL or ORM queries directly |
| CQRS | Commands don't return data; Queries don't change state | Query method with side effects; Command that returns rows |

---

## Architectural Patterns

### 1. MVC (Model-View-Controller)

**Intent:** Separate data (Model), presentation (View), and user-input handling (Controller) into three distinct roles so each can evolve independently.

**Dependency Direction:**
```
Controller → Model
Controller → View
View       → Model (read-only, for rendering)
Model      ✗ never imports View or Controller
```

**Key Invariants**
- Model contains all domain logic and state; zero UI awareness
- Controller orchestrates: it reads user input, tells the Model to change, then selects a View
- View is responsible only for rendering; it delegates all decisions to the Controller

**Violation Signals**
- View contains `if/else` branching on business rules — move to Model or Controller
- Controller exceeds ~50 lines because it also validates, transforms, and persists — Controller should delegate to a service
- Model imports a View type or emits HTML/JSON directly
- Fat Controller anti-pattern: a single Controller method calls 10 different services and handles errors inline

**When to Use:** Web frameworks with request/response cycles (Rails, Django, Laravel, Spring MVC). Desktop apps where the same data drives multiple display panels.

**When NOT to Use:** Rich single-page apps with complex UI state — MVVM or Flux/Redux manage reactive binding better. Real-time apps where the push/pull model of MVC adds latency.

---

### 2. MVP (Model-View-Presenter)

**Intent:** Make the View fully passive — it only displays what the Presenter tells it and forwards all events without processing them.

**Dependency Direction:**
```
Presenter → Model
Presenter → View interface (IView)
View      → Presenter (event delegation only)
Model     ✗ never imported by View
Presenter ✗ never imports concrete View class
```

**Key Invariants**
- View implements a thin interface (`IView`) with methods like `showError()`, `setTitle()`
- Presenter holds all logic; it can be unit-tested without a UI framework
- Model is unaware of both View and Presenter

**Violation Signals**
- View makes a decision: `if (response.status === 'premium') showGoldBadge()` — this belongs in Presenter
- Presenter receives or returns UI-framework types (e.g., `HTMLElement`, `UILabel`) — it should speak in plain data
- View holds a direct reference to the Model (bypasses Presenter)
- Presenter methods test-blocked because they instantiate a real View

**When to Use:** Android apps before Jetpack Compose; desktop UIs (WinForms, Swing) where testability is a priority.

**When NOT to Use:** Frameworks with native data binding (Angular, SwiftUI) — MVVM handles binding more naturally.

---

### 3. MVVM (Model-View-ViewModel)

**Intent:** Bind the View directly to an observable ViewModel so UI state updates propagate automatically without explicit update calls.

**Dependency Direction:**
```
View      ←binding→ ViewModel (one-way or two-way)
ViewModel → Model
Model     ✗ never knows about ViewModel
ViewModel ✗ never imports View or UI-framework types
```

**Key Invariants**
- ViewModel exposes observable properties/streams (e.g., `LiveData`, `StateFlow`, `@Published`)
- ViewModel is instantiable in a plain unit test with no UI framework present
- Model contains domain logic; ViewModel only transforms and exposes data for display

**Violation Signals**
- ViewModel imports `android.widget.*`, `UIKit`, or `React` — it has leaked into the UI layer
- View subscribes to raw Model events, bypassing ViewModel — the binding layer is circumvented
- ViewModel calls `view.update()` explicitly — reverts to MVP, losing declarative binding benefit
- Two-way binding on mutable Model fields — Model state should be immutable; ViewModel maps it

**When to Use:** Reactive UI frameworks (Angular, SwiftUI, Jetpack Compose, WPF). Any app with frequent, data-driven UI updates.

**When NOT to Use:** Simple, static pages where binding overhead exceeds the benefit. Teams unfamiliar with reactive programming — the mental model shifts significantly.

---

### 4. Layered Architecture

**Intent:** Organize code into horizontal layers where each layer only depends on the layer directly beneath it, creating a clear separation of concerns.

**Dependency Direction:**
```
Presentation  →  Business/Application
Business      →  Domain/Service
Domain        →  Data/Infrastructure
Data          ✗  never imports Presentation or Business types
```

**Key Invariants**
- Each layer communicates only with its immediate neighbor (strict layering) or layers below (relaxed layering)
- No layer imports from a layer above it
- Each layer has a clear responsibility boundary: Presentation renders, Business applies rules, Data persists

**Violation Signals**
- Data access object (DAO/Repository) imports a DTO defined in the Presentation layer
- Business service directly calls `res.json()` or manipulates HTTP response objects
- Presentation controller imports a raw database query helper
- "Utility" class in the data layer that all other layers import — creates a circular dependency risk

**When to Use:** Line-of-business applications, enterprise systems, APIs where maintainability and team ownership by layer is a priority.

**When NOT to Use:** Performance-critical paths where the layer traversal adds measurable overhead. Systems so simple a single module suffices.

---

### 5. Clean Architecture

**Intent:** Arrange code in concentric circles where inner circles define abstractions and outer circles provide implementations. Dependency rules are enforced strictly: outer depends on inner, never the reverse.

**Dependency Direction:**
```
Frameworks & Drivers (outermost)
  → Interface Adapters (Controllers, Presenters, Gateways)
    → Use Cases (Application Business Rules)
      → Entities (Enterprise Business Rules, innermost)

No arrow ever points inward-to-outward.
```

**Key Invariants**
- Entities contain enterprise-wide business rules with no framework imports
- Use Cases orchestrate entities; they define repository/gateway *interfaces* but never implement them
- Interface Adapters translate between Use Case data formats and external formats (HTTP, DB)
- The Dependency Inversion Principle resolves the "crossing the boundary" problem: inner layers define interfaces; outer layers implement them

**Violation Signals**
- Entity class has `import { Column, Entity } from 'typeorm'` — ORM decorators in the domain layer
- Use Case directly instantiates a concrete database class instead of depending on a repository interface
- Controller returns a Use Case response object directly to the client (bypasses the Presenter layer)
- Adding a new framework (e.g., switching ORMs) requires changes in Use Case or Entity files

**When to Use:** Long-lived systems with high domain complexity. Teams that need to defer framework choices or swap infrastructure without touching core logic.

**When NOT to Use:** Small CRUD services or prototypes — the ceremony of interfaces, DTOs, and mappers at every boundary adds overhead that is not recovered until the system grows.

**Cross-reference:** `design-patterns-creational-structural` — Repository Pattern (Proxy/Adapter) is the boundary mechanism at the data layer.

---

### 6. Hexagonal Architecture (Ports & Adapters)

**Intent:** Place the domain at the center, define explicit ports (interfaces) for every external interaction, and provide adapters that implement those ports for each technology.

**Dependency Direction:**
```
                ┌────────────────────────────────┐
  HTTP Adapter  │  Port (inbound interface)      │
  CLI Adapter   │         Domain                  │  Port (outbound interface)  DB Adapter
  Test Adapter  │  (zero external imports)       │                              File Adapter
                └────────────────────────────────┘
Adapters depend on Ports. Domain depends on nothing external.
```

**Key Invariants**
- Domain contains all business logic with no external library imports (no HTTP, ORM, queue clients)
- Inbound ports define what the domain can do (use case interfaces)
- Outbound ports define what the domain needs (repository, notification, clock interfaces)
- Adapters implement ports; they may import any framework they need

**Violation Signals**
- Domain class imports `axios`, `pg`, `redis`, or any infrastructure library
- Adapter contains business logic (validation, computation) rather than pure translation
- A single "adapter" serves both the HTTP and the database boundary — two responsibilities
- Tests of domain logic require a running database or HTTP server

**When to Use:** Systems requiring testability of domain logic in isolation. Systems likely to change their delivery mechanism (add CLI, add gRPC, swap DB).

**When NOT to Use:** Services that are truly "dumb pipes" with no meaningful domain logic. Teams not disciplined about port boundaries — without enforcement, adapters accumulate domain logic quickly.

**Cross-reference:** `design-patterns-creational-structural` — Adapter pattern is the implementation mechanism for each hexagonal adapter.

---

### 7. Event-Driven Architecture

**Intent:** Components communicate by publishing events and subscribing to events; producers and consumers are fully decoupled.

**Dependency Direction:**
```
Producer  →  Event Bus / Message Broker
Consumer  →  Event Bus / Message Broker
Producer  ✗  never imports Consumer
Consumer  ✗  never imports Producer
```

**Key Invariants**
- Events represent facts (things that happened): `OrderPlaced`, `PaymentProcessed`
- Producer publishes and forgets — it does not know whether any consumer exists
- Consumer handles events independently and at its own pace (async)
- Event contracts (schema, versioning) are the only coupling point between producer and consumer

**Violation Signals**
- Producer calls a specific consumer's method directly after publishing the event — not event-driven
- Producer `await`s the consumer's response synchronously — collapses to RPC
- Events carry commands ("ProcessOrder") instead of facts ("OrderPlaced") — conflates EDA with command dispatch
- No schema registry or versioning strategy — event contract changes silently break consumers

**When to Use:** Microservices that need loose coupling. Workflows where multiple downstream processes react to the same trigger. Systems where producers and consumers scale independently.

**When NOT to Use:** Operations that require immediate, strongly-consistent responses (payment confirmation to a user). Teams without observability tooling — distributed async flows are hard to debug without tracing and dead-letter queues.

---

### 8. Microservices

**Intent:** Decompose a system into small, independently deployable services, each owning its data and communicating over a network.

**Key Invariants**
- Each service owns and encapsulates its data store — no shared schema
- Services communicate via APIs (REST, gRPC) or events — never direct database access
- Deployment, scaling, and failure of one service does not cascade to others

**Violation Signals**
- Two services share the same database and tables — tight coupling prevents independent deployment
- Service A calls Service B synchronously 10 times per request — creates a distributed monolith
- A library containing domain logic is shared across services — changes require coordinated releases
- No circuit breaker or timeout — failure in one service hangs callers indefinitely

**When to Use:** Organizations with multiple teams that need autonomous ownership. Systems with dramatically different scaling requirements per capability.

**When NOT to Use:** Small teams or early-stage products — the operational overhead (service discovery, distributed tracing, eventual consistency) exceeds the benefit until team and system scale demands it.

---

### 9. Repository Pattern

**Intent:** Abstract data access behind a domain-oriented interface so business logic never knows how or where data is stored.

**Dependency Direction:**
```
Business/Use Case  →  Repository Interface (domain-owned)
Repository Impl    →  Repository Interface (implements)
Repository Impl    →  ORM / DB client (infra-owned)
Business           ✗  never imports ORM or DB client
```

**Key Invariants**
- Repository interface is defined in the domain layer using domain language (`findById`, `save`, `findByEmail`)
- Repository implementation lives in the infrastructure layer and imports the ORM/DB library
- Business logic depends on the interface, not the implementation (Dependency Inversion)

**Violation Signals**
- Service method builds a raw SQL string or ORM query object directly
- Repository interface exposes database concepts (`query()`, `exec()`, `rawSql()`)
- Repository implementation contains business logic (pagination decisions, format transformation with rules)
- Business layer tests require a real database connection because the repository is not abstracted

**When to Use:** Any system where the data source may change (SQL → NoSQL, one ORM to another, external API). Wherever business logic testability without a database is a requirement.

**When NOT to Use:** Pure data APIs with no domain logic — the extra interface adds layers with no payoff. Simple scripts and tooling.

**Cross-reference:** `design-patterns-creational-structural` — Repository is an application of the Proxy / Adapter structural pattern at the data boundary.

---

### 10. CQRS (Command Query Responsibility Segregation)

**Intent:** Separate the write model (Commands that change state) from the read model (Queries that return data) so each can be optimized independently.

**Key Invariants**
- Commands: express intent to change state, return only success/failure or void — never data rows
- Queries: return data, produce no side effects — no state mutation
- Read and write models may use different data stores or representations

**Violation Signals**
- `getUser()` also updates `lastSeenAt` — a query with a side effect
- `createOrder()` returns the full created order object — a command returning query data (may indicate missing event sourcing or separate read model)
- A single model/schema serves both read-optimized views and write operations — under CQRS, they diverge intentionally
- Command handler performs complex joins and projections — indicates missing read model

**When to Use:** Systems with asymmetric read/write load. Event-sourced systems where projections derive read models from events. Complex domains where write rules and read requirements differ significantly.

**When NOT to Use:** Simple CRUD applications — the indirection of separate command/query models is pure overhead. Teams without discipline to maintain two models — they drift and contradict each other.

---

## Decision Flowchart

```
What problem are you solving?

UI separation of concerns?
  ├── View should be passive; testable Presenter  → MVP
  ├── Data binding / reactive UI updates          → MVVM
  └── Basic request/response with server-side render → MVC

Module / service boundary?
  ├── Domain logic must be free of all frameworks  → Hexagonal (Ports & Adapters)
  ├── Multiple concentric abstraction layers        → Clean Architecture
  ├── Horizontal team ownership by responsibility  → Layered Architecture
  └── Independent deployable services              → Microservices

Cross-service or cross-component communication?
  ├── Loose coupling, async, fan-out workflows      → Event-Driven Architecture
  └── Separate read and write optimization          → CQRS

Data access abstraction?
  └── Decouple business from storage technology     → Repository Pattern
```

---

## Common Violations by Anti-Pattern

| Anti-Pattern | Root Cause | Architectural Fix |
|-------------|-----------|------------------|
| Fat Controller | Controller doing service work | Delegate to domain service; Controller only orchestrates |
| Anemic Domain Model | Business logic in service layer, Model is just data | Move logic into Entities (Domain Model pattern) |
| Shared Database | Multiple services accessing one DB directly | Each service owns its schema; sync via events or API |
| Leaky Abstraction | Infrastructure types (ORM entities) used as domain objects | Define domain model separately; use mappers at the boundary |
| Distributed Monolith | Microservices with synchronous call chains | Introduce async events or revisit service boundaries |
| God Service | One service responsible for too many domains | Split by bounded context; each context owns its service |

---

## Cross-References to Design Pattern Skills

| Architectural Pattern | Design Pattern Mechanism | Skill |
|----------------------|-------------------------|-------|
| Hexagonal adapters | Adapter (structural) | `design-patterns-creational-structural` |
| Repository abstraction | Proxy / Adapter | `design-patterns-creational-structural` |
| Clean Architecture boundary crossing | Dependency Inversion via interfaces | `review-solid-clean-code` |
| Event-Driven decoupling | Observer (behavioral) | `design-patterns-behavioral` |
| MVVM data binding | Observer / Mediator | `design-patterns-behavioral` |
| Use Case / Command objects | Command (behavioral) | `design-patterns-behavioral` |
| Facade over subsystem layers | Facade (structural) | `design-patterns-creational-structural` |
