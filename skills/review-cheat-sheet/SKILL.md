---
name: review-cheat-sheet
description: Use when starting any code review and you need a single-page master reference that covers all review dimensions, maps each check to a deeper skill, and tells you when to stop the PR outright
---

# Code Review Cheat Sheet — Master Reference

## Overview

This is the navigator for the entire review skill library. Load this skill first, scan for the relevant phase, follow the check, then jump to the linked skill for deeper guidance. A full review using this sheet takes 20–45 minutes for a typical PR; the First Pass alone takes under 5 minutes.

---

## Severity Quick Reference

| Severity | Label | Action |
|----------|-------|--------|
| Must-fix before merge | **CRITICAL** | Block the PR — do not approve |
| High confidence the change is wrong | **HIGH** | Request changes, do not approve |
| Likely to cause a defect or maintenance burden | **MEDIUM** | Request changes or leave note |
| Style, preference, or minor improvement | **LOW** | Suggest, do not block |
| Optional, reviewer preference | **NIT** | Prefix comment with "nit:" |

---

## Stop the PR (CRITICAL — Must-Fix Before Merge)

Check these first. If any are true, leave a blocking comment immediately and skip the rest of the review until resolved.

- **Security vulnerability present** — hardcoded secret, SQL injection, XSS, auth bypass, path traversal. See `security-patterns-code-review`.
- **Data loss risk** — destructive migration without rollback, DELETE without WHERE, unhandled overwrite of user data. See `database-review-patterns`.
- **Breaking API change without migration** — removed field, renamed endpoint, changed contract with no versioning or deprecation path. See `review-api-contract`.
- **Missing error handling on external calls** — network call, DB query, or third-party SDK call with no error branch. See `error-handling-patterns`.
- **Test suite failing** — CI is red; do not approve a PR on a red build.

---

## Phase 1: First Pass (5 minutes — quick scan before reading any code)

Answer each question. If the answer is "no" or "unsure", flag before deep review.

| Check | Flag if... | Details |
|-------|-----------|---------|
| Does it build and pass CI? | CI is red or not run | Block — see Stop the PR |
| Is the PR reasonably sized? | >400 lines of non-generated code | Ask to split; oversized PRs hide defects |
| Does the commit message explain WHY? | Only describes what, not why | Request a better message |
| Any secrets visible in the diff? | API keys, tokens, passwords in plain text | CRITICAL — stop immediately |
| Any obvious N+1 queries? | Loop around a DB call | Flag for Phase 2 deep dive on `performance-anti-patterns` |
| Any obvious XSS or injection? | Unescaped user input in HTML/SQL | CRITICAL — stop immediately |
| Is the change scoped to one concern? | Mixes refactor + feature + bug fix | Ask to split into separate PRs |

---

## Phase 2: Deep Dive (detailed review by dimension)

Work through each dimension relevant to the PR. Skip dimensions clearly out of scope (e.g., skip "Concurrency" for a UI-only change).

### Logic and Correctness
Deeper skill: `review-code-quality-process`

- Does the code do what the ticket says?
- Are edge cases handled (empty input, zero, null, max values)?
- Are loops and recursion bounded?
- Are conditionals logically correct — no off-by-one, no inverted conditions?
- Are return values checked where the caller could fail silently?

### Security
Deeper skills: `security-patterns-code-review`, `auth-authz-patterns`, `data-validation-schema-patterns`

- All user input validated and sanitized before use (schema-validated at boundary)?
- Parameterized queries used everywhere — no string concatenation into SQL?
- Authentication checked before any privileged operation?
- Authorization enforced at the resource level, not just the route level?
- JWT / session tokens validated (signature, expiry, audience)?
- Sensitive data (PII, tokens) not logged or exposed in responses?
- Rate limiting in place on new endpoints?

### Performance
Deeper skills: `performance-anti-patterns`, `caching-strategies`

- No query inside a loop (N+1)?
- Unbounded queries have LIMIT or pagination?
- No repeated expensive computation where caching would serve?
- Cache invalidation strategy defined (TTL, event-based, or manual purge)?
- Cache key space does not risk collision across tenants or users?
- No synchronous blocking call on a hot path?
- Large collections processed lazily or streamed where possible?

### Data and Database
Deeper skills: `database-review-patterns`, `migration-patterns`, `event-sourcing-cqrs-patterns`

- Migrations are reversible (down migration provided)?
- New columns have sensible defaults or are nullable?
- Indexes added for new filter/join columns?
- Transactions wrap multi-step writes that must be atomic?
- No raw DELETE or UPDATE without a WHERE clause?
- For event sourcing: events are immutable and append-only; projections are rebuildable?
- For CQRS: read model updates are eventually consistent and that is acceptable to the feature?
- Large data migrations use a batched/online strategy, not a single blocking ALTER?

### Error Handling
Deeper skill: `error-handling-patterns`

- Every external call (network, DB, file I/O) has an error branch?
- Errors propagated to callers with context, not silently swallowed?
- User-facing errors are friendly; server-side errors are detailed in logs?
- Retries include backoff; they are not infinite?
- Panics / unhandled exceptions not reachable from normal input paths?

### Testing
Deeper skill: `testing-patterns`

- New behavior has new tests?
- Bug fix has a regression test that would have caught the original bug?
- Tests are isolated — no shared mutable state, no order dependency?
- Mocks used only for external dependencies, not internal logic?
- Coverage of edge cases, not just the happy path?

### API Contract
Deeper skills: `review-api-contract`, `graphql-grpc-api-patterns`, `api-rate-limiting-throttling`

- Request and response schemas are versioned or backward-compatible?
- New required fields have defaults so existing clients do not break?
- Removed fields deprecated first (not deleted in one step)?
- HTTP status codes are semantically correct?
- Error response shape is consistent with existing endpoints?
- For GraphQL: resolver complexity limits, N+1 via DataLoader, schema deprecation tags used correctly?
- For gRPC: proto backward compatibility maintained; field numbers not reused?
- Rate limiting and throttling applied on public-facing or high-traffic endpoints?

### Architecture and Design
Deeper skills: `architectural-patterns`, `domain-driven-design-patterns`, `microservices-resilience-patterns`

- Change fits the existing layer boundaries (no controller reaching into DB directly)?
- No new circular dependencies introduced?
- Abstractions introduced only when there are 2+ concrete cases?
- Does the change respect bounded context boundaries (DDD aggregates, bounded contexts)?
- Would this approach still work at 10x the current load?
- For microservices: circuit breakers, bulkheads, and timeouts in place on inter-service calls?

### Code Smells
Deeper skill: `detect-code-smells`

- No new Long Methods (>30 lines of logic)?
- No new Large Classes (>300 lines with multiple responsibilities)?
- No Duplicate Code that should be extracted?
- No Shotgun Surgery introduced (one concept scattered across files)?
- No Magic Numbers or Strings without named constants?

### Design Patterns Applied Correctly
Deeper skills: `design-patterns-creational-structural`, `design-patterns-behavioral`

- Factory / Builder used where object construction is complex?
- Strategy used where behavior varies by type, not a switch statement?
- Observer / Event used for decoupled notification, not tight callbacks?
- Pattern chosen matches the actual problem, not cargo-culted?

### SOLID and Clean Code
Deeper skill: `review-solid-clean-code`

- Each class/module has one reason to change (SRP)?
- Callers depend on interfaces, not concrete implementations (DIP)?
- New subtypes do not break existing behavior (LSP)?
- Interfaces are narrow — no fat interface forcing empty implementations (ISP)?
- Extension points used instead of modifying existing stable code (OCP)?

### Concurrency
Deeper skill: `concurrency-patterns`

- Shared mutable state is protected (mutex, atomic, channel)?
- No deadlock risk from lock acquisition order?
- Goroutines / threads have defined lifetimes and are cleaned up?
- Race conditions tested with concurrent test tooling where available?

### Observability
Deeper skills: `observability-patterns`, `distributed-tracing-patterns`

- New code paths emit structured logs at appropriate levels?
- Key operations have metrics (counters, histograms) for monitoring?
- Distributed traces propagated through new service calls (trace context headers forwarded)?
- Span tags and baggage set correctly; no sensitive data in trace attributes?
- Alerts or runbooks updated if new failure modes are introduced?

### Dependencies and Module Boundaries
Deeper skill: `dependency-injection-module-patterns`

- New dependency injected (not instantiated inside the component)?
- No new global singletons for stateful resources?
- Third-party package added for a reason — not reinventing what already exists?
- Package version pinned; no unpinned floating major version?

### Language Idioms
Deeper skill: `language-specific-idioms`

- Code follows the conventions of the language (error returns in Go, Result types in Rust, async/await in JS)?
- No anti-patterns specific to the language (mutable default args in Python, `==` on objects in Java)?
- Standard library used where available instead of hand-rolling utilities?

### Messaging and Async Workflows
Deeper skills: `message-queue-patterns`, `data-pipeline-patterns`

- Message producers set appropriate delivery guarantees (at-least-once, exactly-once)?
- Consumers are idempotent — safe to process the same message more than once?
- Dead-letter queues configured for unprocessable messages?
- Backpressure or flow control in place for high-volume pipelines?
- Data pipeline stages handle partial failures without corrupting downstream state?
- Schema of messages/events is versioned and backward-compatible?

### Infrastructure and Deployment
Deeper skills: `container-kubernetes-patterns`, `cicd-pipeline-patterns`, `feature-flags-progressive-delivery`

- Container images use a specific digest or pinned tag, not `latest`?
- Resource requests and limits set on all Kubernetes workloads?
- Liveness and readiness probes configured correctly?
- Secrets mounted via secret store, not baked into image or environment variables in plain text?
- CI pipeline runs tests and security scans before deploying?
- Risky changes wrapped in a feature flag so they can be disabled without a rollback?
- Feature flag cleaned up (removal task filed) after full rollout?

### State Management
Deeper skill: `state-management-patterns`

- Client-side state is normalized — no deeply nested duplicated objects?
- State mutations go through a defined action/reducer path, not direct mutation?
- Derived data computed via selectors, not duplicated in state?
- Side effects (async calls) isolated from pure state update logic?

### Real-Time and Streaming
Deeper skill: `real-time-communication-patterns`

- WebSocket / SSE connections have reconnection logic and exponential backoff?
- Server-side broadcast scoped correctly — messages not leaked to wrong users?
- Message ordering guarantees understood and documented?
- Fallback to polling defined if real-time channel is unavailable?

### Multi-Tenancy
Deeper skill: `multi-tenancy-patterns`

- Every DB query and cache read scoped to the current tenant (no cross-tenant data leak)?
- Tenant-specific configuration loaded correctly without global cache pollution?
- Resource quotas enforced per tenant?

### Search and Indexing
Deeper skill: `search-indexing-patterns`

- Index mappings updated when new fields need to be searchable?
- Index reindex strategy defined for mapping changes (backward-compatible mapping, alias swap)?
- Query complexity bounded — no unbounded wildcard or leading-wildcard queries in production?

### Internationalization and Localization
Deeper skill: `i18n-l10n-patterns`

- All user-visible strings externalized to translation files — no hardcoded display text?
- Date, time, number, and currency formatting uses locale-aware formatters?
- Right-to-left layout tested if supporting RTL locales?
- New translation keys added to all supported locale files (or at minimum the fallback locale)?

### Documentation
Deeper skill: `code-documentation-patterns`

- Public API, exported functions, and complex algorithms have doc comments?
- README or runbook updated if the operational model changed?
- Architecture decision records (ADRs) updated for significant design choices?
- Inline comments explain WHY, not WHAT (code explains what; comments explain why)?

---

## Phase 3: Final Checks (before clicking Approve)

| Check | Done? |
|-------|-------|
| All your comments addressed or responded to? | |
| Tests cover the lines / branches changed? | |
| No TODOs without a linked issue or ticket? | |
| README, changelog, or API docs updated where the interface changed? | |
| No debug code, commented-out blocks, or console.log left in? | |
| Migrations ordered correctly and tested locally if DB change? | |
| Feature flag added for risky or large changes? | |

---

## Cross-References (Full Skill Library)

### Core Review Skills

| Dimension | Skill |
|-----------|-------|
| End-to-end review process | `review-code-quality-process` |
| Security patterns for reviewers | `security-patterns-code-review` |
| Performance anti-patterns | `performance-anti-patterns` |
| Database and migration review | `database-review-patterns` |
| Error handling patterns | `error-handling-patterns` |
| Testing patterns | `testing-patterns` |
| API contract review | `review-api-contract` |
| Architectural patterns | `architectural-patterns` |
| Detecting code smells | `detect-code-smells` |
| Creational and structural design patterns | `design-patterns-creational-structural` |
| Behavioral design patterns | `design-patterns-behavioral` |
| SOLID principles and clean code | `review-solid-clean-code` |
| Concurrency patterns | `concurrency-patterns` |
| Observability patterns | `observability-patterns` |
| Dependency injection and module patterns | `dependency-injection-module-patterns` |
| Language-specific idioms | `language-specific-idioms` |
| Smell-to-refactoring decision aid | `refactoring-decision-matrix` |
| Anti-patterns catalog | `anti-patterns-catalog` |
| Pattern detection walkthroughs | `pattern-detection-walkthroughs` |
| Type system patterns | `type-system-patterns` |

### Architecture and Domain Skills (Cycles 7–10)

| Dimension | Skill |
|-----------|-------|
| Domain-driven design patterns | `domain-driven-design-patterns` |
| Microservices resilience patterns | `microservices-resilience-patterns` |
| Code documentation patterns | `code-documentation-patterns` |
| GraphQL and gRPC API patterns | `graphql-grpc-api-patterns` |
| Event sourcing and CQRS patterns | `event-sourcing-cqrs-patterns` |
| Feature flags and progressive delivery | `feature-flags-progressive-delivery` |
| Data pipeline patterns | `data-pipeline-patterns` |
| Distributed tracing patterns | `distributed-tracing-patterns` |
| CI/CD pipeline patterns | `cicd-pipeline-patterns` |

### Infrastructure and Data Skills (Cycles 11–13)

| Dimension | Skill |
|-----------|-------|
| Caching strategies | `caching-strategies` |
| Message queue patterns | `message-queue-patterns` |
| State management patterns | `state-management-patterns` |
| API rate limiting and throttling | `api-rate-limiting-throttling` |
| Authentication and authorization patterns | `auth-authz-patterns` |
| Data validation and schema patterns | `data-validation-schema-patterns` |
| Migration patterns | `migration-patterns` |
| Container and Kubernetes patterns | `container-kubernetes-patterns` |
| Real-time communication patterns | `real-time-communication-patterns` |
| Multi-tenancy patterns | `multi-tenancy-patterns` |
| Search and indexing patterns | `search-indexing-patterns` |
| Internationalization and localization patterns | `i18n-l10n-patterns` |

### Refactoring Skills

| Dimension | Skill |
|-----------|-------|
| Refactoring overview | `refactor` |
| Composing methods | `refactor-composing-methods` |
| Moving features between objects | `refactor-moving-features` |
| Organizing data | `refactor-organizing-data` |
| Simplifying conditionals | `refactor-simplifying-conditionals` |
| Simplifying method calls | `refactor-simplifying-method-calls` |
| Generalization techniques | `refactor-generalization` |
| Functional refactoring patterns | `refactor-functional-patterns` |
