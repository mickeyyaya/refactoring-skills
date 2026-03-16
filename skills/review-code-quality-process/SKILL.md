---
name: review-code-quality-process
description: Use when conducting a structured code review — covers the full review process across 7 quality dimensions (Logic/Correctness, Security, Performance, Maintainability, Error Handling, Testing, API Design) with actionable questions per dimension, severity classification for findings, and a final review checklist
---

# Review: Code Quality Process

## Overview

This skill defines the process for conducting a thorough code review. It is step-oriented: follow the phases in order, apply the dimension-specific questions, classify every finding by severity, then deliver a structured summary. Where deeper analysis is needed, cross-references point to companion skills.

## When to Use

- Before approving any pull request
- When onboarding reviewers who need a repeatable process
- After detecting code smells that suggest systemic issues (see `detect-code-smells`)
- When a PR is large or complex and needs a structured approach to avoid missing issues

---

## Phase 1: Orientation (Before Reading Code)

Before looking at a single line, orient yourself to avoid reviewing in a vacuum.

**Questions to answer first:**
- What is this PR trying to achieve? Read the description.
- What is the scope? (new feature, bug fix, refactor, dependency update)
- What is the risk surface? (touches auth, payments, data migrations, public API?)
- Are there linked tickets or design docs? Read them.
- What tests are included? Are they in the PR or a separate ticket?

**Checklist:**
- [ ] PR description clearly states the goal
- [ ] Linked ticket or issue is referenced
- [ ] Scope is appropriate — not combining unrelated changes
- [ ] PR size is reviewable (aim for under 400 lines changed; flag large PRs)

---

## Phase 2: Review Dimensions

Work through each dimension in order. Each has a focused question set. Log every finding with its severity before moving to the next dimension.

---

### Dimension 1: Logic and Correctness

**Goal:** Verify the code does what it claims, handles edge cases, and does not introduce regressions.

**Questions:**
- Does the implementation match the stated requirement exactly?
- Are there off-by-one errors in loops, slices, or index access?
- Are null / undefined / empty inputs handled?
- Are boundary values tested? (zero, negative, max values, empty collections)
- Do conditionals cover all branches? Is there an unreachable else branch?
- Are boolean expressions readable and correct? (`&&` vs `||` confusion)
- Does the code handle concurrent access? (shared mutable state, race conditions)
- Does the algorithm terminate? Are there infinite loop risks?
- Are type coercions safe? (implicit casts, integer overflow, float precision)

**Red flags:**
- Functions that return `undefined` on some paths but a value on others
- Conditions that are always true or always false
- Mutating a collection while iterating over it
- Missing `await` on async calls that produce side effects

---

### Dimension 2: Security

**Goal:** Identify vulnerabilities before they reach production. Security issues are always CRITICAL or HIGH.

**Questions:**
- Is all user input validated and sanitized before use?
- Are SQL queries parameterized? (no string concatenation into queries)
- Are HTML outputs escaped? (XSS prevention)
- Are secrets, API keys, or tokens hardcoded anywhere in the diff?
- Is authentication checked on every protected endpoint or resource?
- Is authorization verified? (not just "is this a logged-in user" but "can THIS user do THIS action")
- Are file paths validated to prevent directory traversal?
- Are dependencies pinned to specific versions? Are any new dependencies introduced with known CVEs?
- Is sensitive data (PII, passwords) logged or returned in error messages?
- Are rate limits applied to mutation endpoints?

**Red flags:**
- `query("SELECT * FROM users WHERE id = " + userId)` — SQL injection
- `innerHTML = userInput` — XSS
- `process.env.SECRET_KEY` logged to console
- Missing `authMiddleware` on a route that modifies data
- `require(userProvidedPath)` — path traversal

Cross-reference: `anti-patterns-catalog` → Security Anti-Patterns section.

---

### Dimension 3: Performance

**Goal:** Identify bottlenecks that will degrade under load.

**Questions:**
- Are there N+1 query patterns? (a query inside a loop)
- Are expensive operations (DB queries, HTTP calls, file I/O) called more often than necessary?
- Are results cached when the same data is fetched repeatedly?
- Are there unbounded operations? (processing all records with no limit/pagination)
- Are large payloads transferred when only a subset of fields is needed?
- Are indexes present for the query patterns introduced?
- Are synchronous blocking calls used in an async context?
- Are large data structures allocated in a hot path?
- Are regex patterns compiled once or re-compiled on every call?

**Red flags:**
- `users.forEach(u => db.query(...))` — N+1 pattern
- `SELECT *` on a table with many columns when only 2 are used
- `setInterval` or recurring task with no throttle or circuit breaker
- Loading a full file into memory when streaming would suffice

Cross-reference: `anti-patterns-catalog` → Performance Anti-Patterns section.

---

### Dimension 4: Maintainability

**Goal:** Verify the code can be understood, modified, and extended by a future contributor.

**Questions:**
- Are names descriptive and intention-revealing? (no `data`, `temp`, `x`, `mgr`)
- Are functions focused? (single responsibility, under 30 lines)
- Are files focused? (under 400 lines, cohesive purpose)
- Is there deep nesting? (more than 3-4 levels of indentation signals complex control flow)
- Does the code follow the established conventions in this codebase? (naming, file structure, import order)
- Is there duplicated logic that should be extracted? (see `review-solid-clean-code` → DRY)
- Are magic numbers replaced with named constants?
- Is there commented-out code or TODO comments left without a ticket reference?
- Are abstractions appropriate? Not too many (YAGNI), not too few (duplication)?
- Is the code self-documenting or does it require a comment to explain intent?

**Red flags:**
- Functions named `handleData`, `processInfo`, `doStuff`
- `if (x === 2) { /* what does 2 mean? */ }`
- A 200-line function that does 5 different things
- Deeply nested callbacks or promise chains without named intermediates

Cross-reference: `review-solid-clean-code` for SOLID and clean code violations; `detect-code-smells` for bloater and change preventer smell patterns.

---

### Dimension 5: Error Handling

**Goal:** Verify the system fails safely, communicates clearly, and recovers gracefully.

**Questions:**
- Are all error paths explicitly handled? No empty `catch` blocks?
- Do errors propagate correctly? (not swallowed silently mid-stack)
- Are error messages user-friendly at the UI boundary?
- Are error messages detailed at the server log boundary? (include context: input, state, operation)
- Are external service failures handled with retries, fallbacks, or circuit breakers?
- Does the code restore state (rollback, close resources) on failure?
- Are exceptions typed and specific? (not catching `Exception` / `Error` broadly)
- Is the error surface tested? (negative test cases, failure injection)

**Red flags:**
- `catch (e) {}` — silent swallow
- `catch (e) { console.log(e) }` — log but no recovery or propagation
- `return null` on error when the caller expects a value (hidden null propagation)
- `throw new Error("Something went wrong")` — no context for debugging
- Resource (file handle, DB connection, lock) not closed on exception path

Cross-reference: `anti-patterns-catalog` → Error Handling Anti-Patterns.

---

### Dimension 6: Testing

**Goal:** Verify the change is adequately covered and that tests are meaningful.

**Questions:**
- Is there a test for the happy path?
- Is there a test for each meaningful edge case? (empty, null, boundary, max)
- Is there a test for each error path?
- Do test names describe the scenario and expected behavior? (not `test1`, `shouldWork`)
- Are tests independent? (no shared state between tests, no ordering dependency)
- Are mocks appropriate? (not mocking internals, only mocking external dependencies)
- Is coverage maintained at or above the project threshold?
- Are integration tests present for code that touches the database or external APIs?
- Are existing tests still passing after this change?
- Do tests test behavior or implementation? (prefer behavior — tests should not break on valid refactors)

**Red flags:**
- A new feature with zero corresponding tests
- Tests that assert implementation details (private methods, internal state)
- A single test that covers 12 scenarios in sequence — hard to isolate failures
- `expect(true).toBe(true)` — assertion that always passes

Cross-reference: `anti-patterns-catalog` → Testing Anti-Patterns.

---

### Dimension 7: API Design

**Goal:** Verify that interfaces exposed to callers are consistent, minimal, and backward-compatible.

**Questions:**
- Is the API consistent with existing patterns in this codebase?
- Are parameter names and types consistent with similar functions?
- Are breaking changes introduced? (removed fields, changed types, renamed endpoints)
- Is backward compatibility preserved or explicitly versioned?
- Are return types consistent? (no function that returns `string` sometimes and `null` other times)
- Is the interface minimal? (no leaking of internal implementation details)
- Are optional parameters clearly documented? What are the defaults?
- Are error responses consistent in shape and status codes?
- For HTTP APIs: do status codes match the semantics? (200 for success, 400 for bad input, 404 for not found, 500 for unexpected)

**Red flags:**
- A public function that returns different types depending on internal state
- A new endpoint that uses a different auth strategy from all existing ones
- Removing a field from an API response without a deprecation period
- An HTTP `GET` endpoint that has side effects

Cross-reference: `design-patterns-creational-structural` → Facade (for simplifying complex interface exposure); `refactor-simplifying-method-calls` for API design refactors.

---

## Phase 3: Severity Classification

Every finding logged during Phase 2 must be assigned a severity before the review is delivered.

| Severity | Definition | Action Required |
|----------|-----------|-----------------|
| **CRITICAL** | Security vulnerability, data loss, system crash, or regulatory violation | Block merge — must be fixed before approval |
| **HIGH** | Logic error, race condition, missing auth check, significant performance regression | Block merge — must be fixed before approval |
| **MEDIUM** | Missing tests, unclear naming, missing error handling, maintainability debt | Should be fixed in this PR; may be deferred to a follow-up ticket with agreement |
| **LOW** | Style inconsistency, minor naming improvement, optional optimization, doc gap | Suggest but do not block — leave as a non-blocking comment |
| **NIT** | Micro-style preferences (trailing comma, single vs double quote) | Prefix with "nit:" in the comment — never block on these |

**Decision rule:** A PR with any CRITICAL or HIGH finding must not be approved. A PR with MEDIUM findings should be discussed with the author before approval.

---

## Phase 4: Structured Review Checklist

Use this checklist to confirm all dimensions were covered before submitting the review.

### Orientation and Logic
- [ ] PR description is clear and goal is understood
- [ ] Scope is appropriate — single concern per PR
- [ ] Happy path verified; edge cases (null, empty, boundary) considered
- [ ] No unreachable branches; concurrent access safety confirmed where relevant

### Security
- [ ] All user inputs validated
- [ ] No SQL injection surface
- [ ] No XSS surface in rendered output
- [ ] No secrets hardcoded or logged
- [ ] Auth and authorization verified on all protected paths

### Performance
- [ ] No N+1 query patterns
- [ ] No unbounded data operations
- [ ] Caching applied where appropriate
- [ ] No blocking calls in async context

### Maintainability
- [ ] Names are descriptive and intention-revealing
- [ ] No magic numbers — named constants used
- [ ] No deep nesting (>4 levels)
- [ ] No dead code or orphaned TODOs
- [ ] Follows codebase conventions

### Error Handling
- [ ] No silent catch blocks
- [ ] User-facing errors are friendly; server logs are detailed
- [ ] Resources closed on exception paths
- [ ] External failures handled gracefully

### Testing
- [ ] Happy path covered
- [ ] Edge cases and error paths covered
- [ ] Tests are independent and named descriptively
- [ ] Coverage threshold maintained

### API Design
- [ ] No breaking changes (or explicitly versioned)
- [ ] Return types are consistent
- [ ] Interface is minimal — no leaked internals
- [ ] HTTP semantics correct (status codes, idempotency)

---

## Phase 5: Review Delivery

Structure feedback clearly so the author can act on it efficiently.

**Comment format:**
```
[SEVERITY] <file>:<line> — <finding>

Why this matters: <1 sentence rationale>
Suggested fix: <specific action or code snippet>
```

**Example:**
```
[HIGH] src/api/users.ts:42 — Authorization check missing before update

Why this matters: Any authenticated user can modify another user's profile.
Suggested fix: Add `if (req.user.id !== userId) return res.status(403)` before the update call.
```

**Summary block at top of review:**
```
Reviewed: <PR title>
Findings: X CRITICAL, X HIGH, X MEDIUM, X LOW, X NIT
Decision: APPROVE / REQUEST CHANGES / COMMENT
```

---

## Common Findings at a Glance

| Dimension | Fastest Red Flag | Severity | Fix Reference |
|-----------|-----------------|----------|--------------|
| Logic | Missing `await` on async side-effect | HIGH | — |
| Security | String concatenation into query | CRITICAL | Parameterize query |
| Security | Missing auth check on route | HIGH | Add auth middleware |
| Performance | DB query inside a loop | HIGH | Batch or eager-load |
| Maintainability | 200-line function | MEDIUM | `refactor-composing-methods` |
| Error Handling | Empty `catch` block | HIGH | Handle or propagate |
| Testing | New feature, zero tests | HIGH | Write tests before merge |
| API Design | Breaking field removal | HIGH | Version the API |

---

## Cross-References

| Topic | Related Skill |
|-------|--------------|
| SOLID violations and clean code quality | `review-solid-clean-code` |
| Detecting bloater, coupler, change preventer smells | `detect-code-smells` |
| Extract Method, Extract Variable, Substitute Algorithm | `refactor-composing-methods` |
| Extract Class, Move Method, Hide Delegate | `refactor-moving-features` |
| Extract Interface, Replace Inheritance with Delegation | `refactor-generalization` |
| Rename Method, Add Parameter, Separate Query from Modifier | `refactor-simplifying-method-calls` |
| Replace Magic Number, Encapsulate Field | `refactor-organizing-data` |
| Decompose Conditional, Replace Nested Conditional with Guard | `refactor-simplifying-conditionals` |
| Strategy, Observer, Command patterns (behavioral fixes) | `design-patterns-behavioral` |
| Factory, Facade, Adapter patterns (structural fixes) | `design-patterns-creational-structural` |
| Architecture-level review concerns | `architectural-patterns` |
| Anti-patterns to watch for across all dimensions | `anti-patterns-catalog` |
