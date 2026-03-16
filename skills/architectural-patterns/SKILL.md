---
name: architectural-patterns
description: Use when reviewing code for architectural boundary violations, dependency direction errors, or layer coupling issues — covers 10 architectural patterns with invariants, violation signals, and dependency diagrams
---

# Architectural Patterns Review Skill

## Overview

Architectural patterns define large-scale structure: how major components communicate, dependency direction, and where responsibilities live. Unlike GoF patterns (class level), these operate at module, service, and system level. Review asks: "Are boundaries intact? Are dependencies flowing correctly? Is this component doing work that belongs elsewhere?"

## When to Use

- PR adds a new layer dependency or import
- Evaluating whether a new service/module belongs where the author placed it
- Diagnosing why a codebase is hard to test despite "clean" individual classes
- Assessing whether stated architecture matches actual code

## Quick Reference

| Pattern | Core Invariant | Key Violation Signal |
|---------|---------------|---------------------|
| MVC | Model never imports View | View contains business logic; fat Controller |
| MVP | View is passive; Presenter mediates | View makes decisions; Presenter imports View type |
| MVVM | ViewModel does not know View | ViewModel imports UI framework types |
| Layered | Dependencies flow downward only | Data layer imports Presentation types |
| Clean Architecture | Inner circles never depend on outer | Entity imports from framework layer |
| Hexagonal | Domain has zero external dependencies | Domain imports HTTP, ORM, or DB libraries |
| Event-Driven | Producers don't know consumers | Producer awaits consumer response synchronously |
| Microservices | Each service owns its data | Shared database across services |
| Repository | Business logic doesn't know storage | Service builds raw SQL or ORM queries directly |
| CQRS | Commands don't return data; Queries don't mutate | Query with side effects; Command returning rows |

---

## Architectural Patterns

### 1. MVC (Model-View-Controller)

**Dependency Direction:**
```
Controller → Model
Controller → View
View       → Model (read-only, for rendering)
Model      ✗ never imports View or Controller
```

**Key Invariants:** Model contains all domain logic with zero UI awareness. Controller orchestrates: reads input, tells Model to change, selects View. View only renders, delegating decisions to Controller.

**Violation Signals:** View contains business-rule branching; Controller exceeds ~50 lines (validate+transform+persist); Model emits HTML/JSON; Fat Controller calling 10+ services inline.

**Use when** web frameworks with request/response cycles. **Skip when** rich SPAs with complex UI state (MVVM/Redux better) or real-time apps where push/pull adds latency.

---

### 2. MVP (Model-View-Presenter)

**Dependency Direction:**
```
Presenter → Model
Presenter → View interface (IView)
View      → Presenter (event delegation only)
Model     ✗ never imported by View
Presenter ✗ never imports concrete View class
```

**Key Invariants:** View implements a thin interface (`showError()`, `setTitle()`). Presenter holds all logic, unit-testable without UI framework. Model unaware of both.

**Violation Signals:** View makes decisions (`if (response.status === 'premium') showGoldBadge()`); Presenter receives UI-framework types; View holds direct Model reference; Presenter test-blocked by real View instantiation.

**Use when** Android (pre-Compose), desktop UIs needing testability. **Skip when** frameworks with native data binding (Angular, SwiftUI) — MVVM fits better.

---

### 3. MVVM (Model-View-ViewModel)

**Dependency Direction:**
```
View      ←binding→ ViewModel (one-way or two-way)
ViewModel → Model
Model     ✗ never knows about ViewModel
ViewModel ✗ never imports View or UI-framework types
```

**Key Invariants:** ViewModel exposes observable properties/streams. ViewModel instantiable in a plain unit test. Model contains domain logic; ViewModel only transforms data for display.

**Violation Signals:** ViewModel imports `android.widget.*`, `UIKit`, or `React`; View subscribes to raw Model events bypassing ViewModel; ViewModel calls `view.update()` explicitly; two-way binding on mutable Model fields.

**Use when** reactive UI frameworks (Angular, SwiftUI, Jetpack Compose, WPF). **Skip when** simple static pages or teams unfamiliar with reactive programming.

---

### 4. Layered Architecture

**Dependency Direction:**
```
Presentation  →  Business/Application
Business      →  Domain/Service
Domain        →  Data/Infrastructure
Data          ✗  never imports Presentation or Business types
```

**Key Invariants:** Each layer communicates only with its immediate neighbor (strict) or layers below (relaxed). No upward imports. Clear responsibility boundary per layer.

**Violation Signals:** DAO imports a Presentation DTO; business service calls `res.json()`; controller imports raw DB query helper; "utility" class in data layer imported by all others (circular dependency risk).

**Use when** line-of-business applications, enterprise systems, APIs with team ownership by layer. **Skip when** performance-critical paths where layer traversal adds overhead, or trivially simple systems.

---

### 5. Clean Architecture

**Dependency Direction:**
```
Frameworks & Drivers (outermost)
  → Interface Adapters (Controllers, Presenters, Gateways)
    → Use Cases (Application Business Rules)
      → Entities (Enterprise Business Rules, innermost)

No arrow ever points inward-to-outward.
```

**Key Invariants:** Entities have no framework imports. Use Cases define repository/gateway *interfaces* but never implement them. Interface Adapters translate between Use Case and external formats. Dependency Inversion resolves boundary crossing.

**Violation Signals:** Entity has ORM decorators (`import { Column } from 'typeorm'`); Use Case instantiates concrete DB class; Controller returns Use Case response directly; switching ORMs requires Entity changes.

**Use when** long-lived systems with high domain complexity. **Skip when** small CRUD services — interface/DTO/mapper ceremony at every boundary isn't recovered until the system grows.

---

### 6. Hexagonal Architecture (Ports & Adapters)

**Dependency Direction:**
```
              ┌────────────────────────────────┐
HTTP Adapter  │  Port (inbound interface)      │
CLI Adapter   │         Domain                  │  Port (outbound interface)  DB Adapter
Test Adapter  │  (zero external imports)       │                              File Adapter
              └────────────────────────────────┘
Adapters depend on Ports. Domain depends on nothing external.
```

**Key Invariants:** Domain has no external library imports (no HTTP, ORM, queue clients). Inbound ports define what domain can do. Outbound ports define what domain needs. Adapters implement ports.

**Violation Signals:** Domain imports `axios`, `pg`, `redis`; adapter contains business logic; single adapter serves both HTTP and DB boundaries; domain tests require running infrastructure.

**Use when** testability of domain logic in isolation, or likely delivery mechanism changes. **Skip when** truly "dumb pipe" services with no meaningful domain logic, or teams not disciplined about port boundaries.

---

### 7. Event-Driven Architecture

**Dependency Direction:**
```
Producer  →  Event Bus / Message Broker
Consumer  →  Event Bus / Message Broker
Producer  ✗  never imports Consumer
Consumer  ✗  never imports Producer
```

**Key Invariants:** Events represent facts (`OrderPlaced`, `PaymentProcessed`). Producer publishes and forgets. Consumer handles independently and async. Event contracts (schema, versioning) are the only coupling point.

**Violation Signals:** Producer calls consumer's method after publishing; producer `await`s consumer response (collapses to RPC); events carry commands instead of facts; no schema registry or versioning.

**Use when** microservices needing loose coupling, fan-out workflows, independent scaling. **Skip when** immediate strongly-consistent responses required, or teams lack observability tooling for distributed async flows.

---

### 8. Microservices

**Key Invariants:** Each service owns its data store — no shared schema. Services communicate via APIs or events, never direct DB access. Deployment/scaling/failure doesn't cascade.

**Violation Signals:** Two services share DB tables; Service A calls B synchronously 10 times per request (distributed monolith); shared domain logic library requires coordinated releases; no circuit breaker or timeout.

**Use when** multiple teams needing autonomous ownership with different scaling requirements. **Skip when** small teams or early-stage — operational overhead (discovery, tracing, eventual consistency) exceeds benefit.

---

### 9. Repository Pattern

**Dependency Direction:**
```
Business/Use Case  →  Repository Interface (domain-owned)
Repository Impl    →  Repository Interface (implements)
Repository Impl    →  ORM / DB client (infra-owned)
Business           ✗  never imports ORM or DB client
```

**Key Invariants:** Interface defined in domain layer using domain language (`findById`, `save`). Implementation in infrastructure layer. Business depends on interface, not implementation (Dependency Inversion).

**Violation Signals:** Service builds raw SQL or ORM query; repository interface exposes DB concepts (`query()`, `rawSql()`); repository contains business logic; tests require a real DB because repository isn't abstracted.

**Use when** data source may change or business logic needs testing without DB. **Skip when** pure data APIs with no domain logic or simple scripts.

---

### 10. CQRS (Command Query Responsibility Segregation)

**Key Invariants:** Commands express intent to change state, return only success/failure — never data rows. Queries return data with no side effects. Read and write models may use different data stores.

**Violation Signals:** `getUser()` updates `lastSeenAt` (query with side effect); `createOrder()` returns full created object (command returning query data); single schema serves both read and write; command handler performs complex joins.

**Use when** asymmetric read/write load, event-sourced systems, complex domains where write rules and read needs differ. **Skip when** simple CRUD — separate models add pure overhead.

---

## Decision Flowchart

```
UI separation of concerns?
  ├── Passive view; testable Presenter          → MVP
  ├── Data binding / reactive UI updates        → MVVM
  └── Basic request/response, server-side render → MVC

Module / service boundary?
  ├── Domain free of all frameworks             → Hexagonal
  ├── Multiple concentric abstraction layers    → Clean Architecture
  ├── Horizontal team ownership by responsibility → Layered
  └── Independent deployable services           → Microservices

Cross-service / cross-component communication?
  ├── Loose coupling, async, fan-out workflows  → Event-Driven
  └── Separate read and write optimization      → CQRS

Data access abstraction?
  └── Decouple business from storage technology → Repository
```

---

## Common Violations by Anti-Pattern

| Anti-Pattern | Root Cause | Fix |
|-------------|-----------|-----|
| Fat Controller | Controller doing service work | Delegate to domain service |
| Anemic Domain Model | Logic in service layer, Model is just data | Move logic into Entities |
| Shared Database | Multiple services accessing one DB | Each service owns schema; sync via events/API |
| Leaky Abstraction | ORM entities used as domain objects | Separate domain model; mappers at boundary |
| Distributed Monolith | Synchronous call chains across services | Async events or revisit service boundaries |
| God Service | One service for too many domains | Split by bounded context |

---

## Cross-References

| Architectural Pattern | Design Pattern Mechanism | Skill |
|----------------------|-------------------------|-------|
| Hexagonal adapters | Adapter (structural) | `design-patterns-creational-structural` |
| Repository abstraction | Proxy / Adapter | `design-patterns-creational-structural` |
| Clean Architecture boundary | Dependency Inversion via interfaces | `review-solid-clean-code` |
| Event-Driven decoupling | Observer (behavioral) | `design-patterns-behavioral` |
| MVVM data binding | Observer / Mediator | `design-patterns-behavioral` |
| Use Case / Command objects | Command (behavioral) | `design-patterns-behavioral` |
| Facade over subsystem layers | Facade (structural) | `design-patterns-creational-structural` |
