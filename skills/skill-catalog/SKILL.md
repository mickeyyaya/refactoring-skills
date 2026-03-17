---
name: skill-catalog
description: Master navigation and dispatch index for all 70 skills — invoke this skill first when unsure which skill covers your task. Maps common scenarios, tasks, and questions to the right skill via a quick dispatch table, domain category index, and decision FAQ.
---

# Skill Catalog — Navigation & Dispatch Index

## Overview

This catalog is the entry point for the entire skill library. When you are unsure which skill to use, start here. The catalog maps common tasks and scenarios to the right skill so you spend less time searching and more time doing.

**When to use:** Any time you are unsure which skill applies to your current task, are looking for a skill by domain or keyword, want to see what coverage the library provides, or need to cross-reference related skills for a complex task.

This is a pure navigation document — it does not teach patterns itself. Each listed skill contains the full detail, examples, red flags, and language-specific code.

---

### Quick Dispatch Table

Use this table for fast lookup. Find the scenario closest to your current task, then open the mapped skill.

| Scenario / Task | Skill to Use |
|-----------------|--------------|
| Unsure which skill applies | You are here — read the category index below |
| Code smells, unclear ownership, long methods | `detect-code-smells` |
| Move, extract, inline, or rename code safely | `refactor` |
| Break large methods into smaller steps | `refactor-composing-methods` |
| Replace conditionals, loops, or callbacks with FP | `refactor-functional-patterns` |
| Simplify long `if/else` chains or switch blocks | `refactor-simplifying-conditionals` |
| Simplify method signatures or argument lists | `refactor-simplifying-method-calls` |
| Move fields, methods between classes | `refactor-moving-features` |
| Replace primitives with classes, enums, objects | `refactor-organizing-data` |
| Abstract or generalize duplicated logic | `refactor-generalization` |
| Decide whether and how to refactor | `refactoring-decision-matrix` |
| Choose creational or structural design patterns | `design-patterns-creational-structural` |
| Choose behavioral design patterns | `design-patterns-behavioral` |
| Detect which patterns exist in code | `pattern-detection-walkthroughs` |
| Full PR review workflow | `review-code-quality-process` |
| SOLID principles and clean code review | `review-solid-clean-code` |
| API contract and REST interface review | `review-api-contract` |
| Quick review checklist reference | `review-cheat-sheet` |
| Detect anti-patterns and performance issues | `anti-patterns-catalog` |
| CPU/memory/database performance anti-patterns | `performance-anti-patterns` |
| Error handling, retry, circuit breaker | `error-handling-patterns` |
| Async, concurrency, race conditions, locking | `concurrency-patterns` |
| Type safety, generics, branded types | `type-system-patterns` |
| Dependency injection, inversion of control | `dependency-injection-module-patterns` |
| Language-specific idioms (Go, Rust, Python, TS, Java) | `language-specific-idioms` |
| Security review, injection, secrets, OWASP | `security-patterns-code-review` |
| Authentication and authorization patterns | `auth-authz-patterns` |
| Multi-tenant data isolation, scoping | `multi-tenancy-patterns` |
| REST API design, versioning, pagination | `review-api-contract` |
| GraphQL schema design, gRPC service definitions | `graphql-grpc-api-patterns` |
| Rate limiting, throttling, quota management | `api-rate-limiting-throttling` |
| WebSockets, SSE, real-time push | `real-time-communication-patterns` |
| Message queues, pub/sub, broker patterns | `message-queue-patterns` |
| Database queries, indexes, transactions | `database-review-patterns` |
| Caching strategy, eviction, cache invalidation | `caching-strategies` |
| Search indexes, Elasticsearch, query optimization | `search-indexing-patterns` |
| ETL, data pipelines, streaming | `data-pipeline-patterns` |
| Input validation, schema validation, parsing | `data-validation-schema-patterns` |
| Architectural decisions, layering, hexagonal | `architectural-patterns` |
| Domain-driven design, bounded contexts | `domain-driven-design-patterns` |
| Event sourcing, CQRS, projections | `event-sourcing-cqrs-patterns` |
| Microservices, resilience, service mesh | `microservices-resilience-patterns` |
| Database migrations, schema evolution | `migration-patterns` |
| CI/CD pipelines, automated delivery | `cicd-pipeline-patterns` |
| Container orchestration, Kubernetes patterns | `container-kubernetes-patterns` |
| Feature flags, progressive delivery, canary | `feature-flags-progressive-delivery` |
| Observability, metrics, alerting | `observability-patterns` |
| Distributed tracing, span propagation | `distributed-tracing-patterns` |
| Frontend state management, Flux, Redux | `state-management-patterns` |
| Internationalization, localization, locale | `i18n-l10n-patterns` |
| Code documentation, docstrings, ADRs | `code-documentation-patterns` |
| Testing strategy, unit/integration/E2E | `testing-patterns` |
| Building an AI feature, RAG pipeline, prompt engineering | `ai-ml-integration-patterns` |
| LLM tool use, function calling, structured output, hallucination mitigation | `ai-ml-integration-patterns` |
| Monorepo tooling, dev containers, platform engineering, DX-first API design | `developer-experience-patterns` |
| Developer onboarding, local-prod parity, fast feedback loops | `developer-experience-patterns` |
| File upload, presigned URLs, resumable uploads, upload security | `file-upload-media-patterns` |
| Image optimization, async media processing, CDN transforms, content-addressable storage | `file-upload-media-patterns` |
| Calibrate review confidence, reduce false positives, tune severity | `review-accuracy-calibration` |
| Review LLM-generated or AI-assisted code | `ai-generated-code-review` |
| Write actionable, clear review feedback comments | `review-feedback-quality` |
| Risk-based review ordering, time-boxing, when to stop reviewing | `review-efficiency-patterns` |
| Select static analysis tools, configure CI quality gates | `review-automation-patterns` |
| Apply universal review signals across any language | `cross-language-review-heuristics` |
| Review Go code: goroutine leaks, context propagation, error handling | `go-review-patterns` |
| Review Python code: mutable defaults, type hints, GIL, idioms | `python-review-patterns` |
| Review TypeScript code: type escape hatches, async pitfalls, React hooks | `typescript-review-patterns` |
| Review Rust code: ownership, borrowing, unsafe blocks, lifetimes | `rust-review-patterns` |
| Review Java code: null safety, Stream API, concurrency, generics | `java-review-patterns` |
| Review C++ code: RAII, undefined behavior, templates, move semantics | `cpp-review-patterns` |
| End-to-end PR review orchestration, full workflow from load to verdict | `pr-review-workflow` |
| Measure review effectiveness: defect escape rate, cycle time, comment resolution | `review-metrics` |
| End-to-end review diagnostic walkthroughs across security, performance, concurrency | `review-walkthroughs` |

---

### Category Index by Domain

The 70 skills are organized into 15 domains. Use this index when you want to explore an area broadly rather than targeting a specific task.

---

#### Refactoring (10 skills)

Improve the internal structure of code without changing observable behavior.

| Skill | Purpose |
|-------|---------|
| `refactor` | Core refactoring moves: extract, inline, rename, move |
| `refactor-composing-methods` | Decompose large functions into well-named steps |
| `refactor-functional-patterns` | Replace imperative code with FP constructs (map, filter, reduce, monads) |
| `refactor-simplifying-conditionals` | Eliminate nested `if/else`, introduce guard clauses and polymorphism |
| `refactor-simplifying-method-calls` | Clean up method signatures, parameter objects, builder patterns |
| `refactor-moving-features` | Move fields and behavior to their rightful class or module |
| `refactor-organizing-data` | Replace primitives with domain objects, introduce value types |
| `refactor-generalization` | DRY up duplicated logic via abstraction and parameterization |
| `refactoring-decision-matrix` | Decide when to refactor and which technique fits the situation |
| `detect-code-smells` | Identify long methods, large classes, feature envy, and other smells |

---

#### Design Patterns (3 skills)

Classic GoF and modern patterns for structuring objects and interactions.

| Skill | Purpose |
|-------|---------|
| `design-patterns-creational-structural` | Factory, Builder, Singleton, Adapter, Decorator, Facade, Proxy |
| `design-patterns-behavioral` | Strategy, Observer, Command, Iterator, State, Chain of Responsibility |
| `pattern-detection-walkthroughs` | Read existing code to identify which patterns are already in use |

---

#### Code Review (20 skills)

Structured review processes and checklists for PRs and design documents.

| Skill | Purpose |
|-------|---------|
| `review-code-quality-process` | End-to-end PR review workflow covering readability, correctness, tests |
| `review-solid-clean-code` | SOLID principles, DRY, law of Demeter, clean code checklist |
| `review-api-contract` | REST API design review: versioning, pagination, error contracts |
| `review-cheat-sheet` | One-page quick-reference checklist for common review criteria |
| `anti-patterns-catalog` | Catalog of well-known anti-patterns to flag during review |
| `review-accuracy-calibration` | Confidence scoring, false positive reduction, severity calibration |
| `ai-generated-code-review` | Patterns for reviewing LLM-generated and AI-assisted code |
| `review-feedback-quality` | How to write actionable, clear review comments |
| `review-efficiency-patterns` | Risk-based ordering, time-boxing, when to stop reviewing |
| `review-automation-patterns` | Static analysis tool selection, CI gate configuration |
| `cross-language-review-heuristics` | Universal review signals that apply across all languages |
| `go-review-patterns` | Goroutine leaks, context propagation, idiomatic error handling in Go |
| `python-review-patterns` | Mutable defaults, type hints, GIL awareness, Pythonic idioms |
| `typescript-review-patterns` | Type escape hatches, async pitfalls, React hooks review |
| `rust-review-patterns` | Ownership and borrowing, unsafe blocks, lifetime annotations |
| `java-review-patterns` | Null safety, Stream API misuse, concurrency, generics |
| `cpp-review-patterns` | RAII, undefined behavior, templates, move semantics |
| `pr-review-workflow` | Capstone skill — sequences all review skills into one time-boxed PR workflow |
| `review-metrics` | Defect escape rate, false positive rate, cycle time, and coverage metrics |
| `review-walkthroughs` | End-to-end diagnostic walkthroughs across security, performance, and concurrency |

---

#### Anti-Patterns and Performance (2 skills)

Detect and fix common performance problems and architectural mistakes.

| Skill | Purpose |
|-------|---------|
| `anti-patterns-catalog` | God objects, spaghetti code, golden hammer, and more |
| `performance-anti-patterns` | N+1 queries, memory leaks, unbounded growth, blocking the event loop |

---

#### Cross-Cutting Concerns (5 skills)

Concerns that apply across every layer and domain of an application.

| Skill | Purpose |
|-------|---------|
| `error-handling-patterns` | Result types, exception hierarchies, retry, circuit breaker, DLQ |
| `concurrency-patterns` | Async/await, thread safety, actors, lock-free data structures |
| `type-system-patterns` | Generics, branded/nominal types, type narrowing, variance |
| `dependency-injection-module-patterns` | IoC containers, manual DI, module boundaries |
| `language-specific-idioms` | Go, Rust, Python, TypeScript, and Java idiomatic style |

---

#### Security and Auth (3 skills)

Protect data, control access, and isolate tenants.

| Skill | Purpose |
|-------|---------|
| `security-patterns-code-review` | OWASP Top 10, injection, secrets management, secure headers |
| `auth-authz-patterns` | OAuth2, JWT, RBAC, ABAC, session management, authentication flows |
| `multi-tenancy-patterns` | Tenant isolation strategies, row-level security, scoped queries |

---

#### API and Communication (5 skills)

Design and implement service interfaces and communication protocols.

| Skill | Purpose |
|-------|---------|
| `review-api-contract` | REST design, HTTP semantics, versioning, pagination, error contracts |
| `graphql-grpc-api-patterns` | GraphQL schema, resolvers, N+1 avoidance, gRPC service design |
| `api-rate-limiting-throttling` | Token bucket, leaky bucket, sliding window, quota enforcement |
| `real-time-communication-patterns` | WebSockets, SSE, long polling, pub/sub push delivery |
| `message-queue-patterns` | Queue topologies, at-least-once delivery, idempotency, dead letter queues |

---

#### Data and Storage (5 skills)

Manage persistence, caching, retrieval, and data quality.

| Skill | Purpose |
|-------|---------|
| `database-review-patterns` | Query optimization, index design, transactions, ORM pitfalls |
| `caching-strategies` | Cache-aside, write-through, eviction policies, cache invalidation |
| `search-indexing-patterns` | Full-text search, Elasticsearch mappings, query tuning |
| `data-pipeline-patterns` | ETL/ELT, streaming pipelines, backfill, idempotent transforms |
| `data-validation-schema-patterns` | Schema definition, parsing at boundaries, sanitization |

---

#### Architecture and Migration (5 skills)

Structure systems at the macro scale and evolve them safely over time.

| Skill | Purpose |
|-------|---------|
| `architectural-patterns` | Hexagonal, layered, CQRS, event-driven, monolith-to-service |
| `domain-driven-design-patterns` | Bounded contexts, aggregates, value objects, domain events |
| `event-sourcing-cqrs-patterns` | Event store, projections, read models, eventual consistency |
| `microservices-resilience-patterns` | Bulkheads, sidecar, service mesh, health checks, cascading failure |
| `migration-patterns` | Schema migrations, blue/green data migrations, backward compatibility |

---

#### DevOps and Infrastructure (5 skills)

Deliver, deploy, observe, and operate software reliably.

| Skill | Purpose |
|-------|---------|
| `cicd-pipeline-patterns` | Pipeline stages, artifact management, deployment gates, rollback |
| `container-kubernetes-patterns` | Dockerfile best practices, pod specs, resource limits, Kubernetes patterns |
| `feature-flags-progressive-delivery` | Flag systems, canary releases, kill switches, gradual rollouts |
| `observability-patterns` | Metrics, structured logging, dashboards, alerting, SLOs |
| `distributed-tracing-patterns` | Trace context propagation, span design, sampling, Jaeger/Tempo |

---

#### Frontend and UX (2 skills)

Manage client-side complexity and reach a global user base.

| Skill | Purpose |
|-------|---------|
| `state-management-patterns` | Flux, Redux, Zustand, derived state, optimistic updates |
| `i18n-l10n-patterns` | Message catalogs, pluralization, locale detection, RTL layout |

---

#### Documentation and Testing (2 skills)

Keep knowledge accessible and behavior verified.

| Skill | Purpose |
|-------|---------|
| `code-documentation-patterns` | Docstrings, ADRs, README structure, living documentation |
| `testing-patterns` | Test pyramid, unit/integration/E2E, test doubles, mutation testing |

---

#### AI & ML Integration (1 skill)

Design and review code that integrates large language models and ML systems.

| Skill | Purpose |
|-------|---------|
| `ai-ml-integration-patterns` | RAG pipelines, prompt engineering, structured output, tool use/function calling, LLM error handling, token budget management, hallucination mitigation, AI/ML anti-patterns |

---

#### Developer Experience (1 skill)

Build and improve the internal developer platform, tooling, and workflows.

| Skill | Purpose |
|-------|---------|
| `developer-experience-patterns` | Monorepo tooling (Nx/Turborepo), dev containers, golden path / platform engineering, local-prod parity, fast feedback loops, DX-first API design, developer onboarding |

---

#### File & Media Processing (1 skill)

Design and review file upload pipelines and media processing systems.

| Skill | Purpose |
|-------|---------|
| `file-upload-media-patterns` | Presigned URL direct-to-storage uploads, resumable uploads (tus/S3 multipart), upload security pipeline (MIME validation, virus scanning, quarantine), async media processing, image optimization, CDN transforms, content-addressable storage |

---

### What Skill For...? — Decision FAQ

Common questions that land in the catalog and the right skill to reach for.

---

#### "My PR touches database queries and I want to check for N+1 problems."

Use `database-review-patterns` for query analysis and ORM pitfalls. Also check `performance-anti-patterns` for the N+1 anti-pattern in depth.

---

#### "I have a large class with too many responsibilities. Where do I start?"

Use `detect-code-smells` to identify what smells are present (Large Class, Feature Envy, etc.). Then use `refactoring-decision-matrix` to choose which refactoring technique is appropriate, and open the specific refactoring skill (e.g., `refactor-moving-features` to redistribute responsibilities).

---

#### "I need to review a PR for security issues."

Use `security-patterns-code-review` for OWASP-level concerns (injection, secrets, headers). If the PR includes authentication logic, layer in `auth-authz-patterns`. For multi-tenant SaaS, also check `multi-tenancy-patterns` for scoping violations.

---

#### "We are adding retries to an API client. What could go wrong?"

Use `error-handling-patterns` (Retry with Exponential Backoff section). Cross-reference `concurrency-patterns` if using async retry in a concurrent context, and `api-rate-limiting-throttling` if the upstream enforces rate limits.

---

#### "We are choosing between REST and GraphQL for a new API."

Use `review-api-contract` for REST considerations. Use `graphql-grpc-api-patterns` for GraphQL schema design and N+1 avoidance with dataloaders. If throughput control matters, layer in `api-rate-limiting-throttling`.

---

#### "We want to add observability to our microservices."

Use `observability-patterns` for metrics and structured logging. Add `distributed-tracing-patterns` for trace propagation across service boundaries. If you are deploying to Kubernetes, see `container-kubernetes-patterns` for health check and readiness probe patterns.

---

#### "We are migrating from a monolith to microservices."

Start with `architectural-patterns` for the overall decomposition strategy. Then use `microservices-resilience-patterns` for resilience patterns (bulkheads, circuit breakers, health checks). Use `migration-patterns` for the database and data migration steps. For event-driven decomposition, also read `event-sourcing-cqrs-patterns`.

---

#### "I want to introduce feature flags for a canary release."

Use `feature-flags-progressive-delivery` for flag system design and canary rollout patterns. Cross-reference `cicd-pipeline-patterns` for deployment gate integration and `observability-patterns` for flagging metrics dashboards.

---

#### "Our codebase has grown and I am not sure what patterns are already in use."

Use `pattern-detection-walkthroughs` to read existing code and identify GoF patterns in practice. Then cross-reference `design-patterns-creational-structural` or `design-patterns-behavioral` for the specific pattern you found.

---

#### "We are building a multi-tenant SaaS app. What do I need to think about?"

Use `multi-tenancy-patterns` as the primary skill. Supplement with `auth-authz-patterns` for tenant-scoped authorization and `security-patterns-code-review` to ensure tenant data cannot leak across boundaries.

---

### Coverage Summary

| Domain | Skill Count |
|--------|-------------|
| Refactoring | 10 |
| Design Patterns | 3 |
| Code Review | 20 |
| Anti-Patterns and Performance | 2 |
| Cross-Cutting Concerns | 5 |
| Security and Auth | 3 |
| API and Communication | 5 |
| Data and Storage | 5 |
| Architecture and Migration | 5 |
| DevOps and Infrastructure | 5 |
| Frontend and UX | 2 |
| Documentation and Testing | 2 |
| AI & ML Integration | 1 |
| Developer Experience | 1 |
| File & Media Processing | 1 |
| **Total** | **70** |

Note: Some skills appear in multiple categories because they cross domain boundaries (e.g., `anti-patterns-catalog` is listed under both Code Review and Anti-Patterns). The unique skill count in the library is 69.

---

### How to Add a New Skill to This Catalog

When a new skill is created in the library:

1. Add a row to the Quick Dispatch Table with the primary scenario it handles.
2. Add it to the appropriate Category Index section.
3. If it answers a common "what skill for...?" question, add an FAQ entry.
4. Update the Coverage Summary count.

Keep this catalog as the single source of truth for skill discovery. Do not duplicate skill content here — link to the skill and describe its purpose in one sentence.
