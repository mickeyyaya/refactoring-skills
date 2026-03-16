---
name: review-code-quality-process
description: Use when conducting a structured code review — covers the full review process across 7 quality dimensions (Logic/Correctness, Security, Performance, Maintainability, Error Handling, Testing, API Design) with actionable questions per dimension, severity classification for findings, and a final review checklist
---

# Review: Code Quality Process

## Overview

Step-oriented code review process: follow phases in order, apply dimension-specific questions, classify findings by severity, deliver a structured summary.

## When to Use

- Before approving any pull request
- After detecting code smells suggesting systemic issues (see `detect-code-smells`)
- When a PR is large or complex and needs structured coverage

---

## Phase 1: Orientation (Before Reading Code)

**Answer first:**
- What is this PR trying to achieve? (read description)
- Scope? (feature, bug fix, refactor, dependency update)
- Risk surface? (auth, payments, data migrations, public API?)
- Linked tickets or design docs?
- Tests included or deferred?

**Checklist:**
- [ ] PR description states the goal
- [ ] Linked ticket referenced
- [ ] Single concern per PR
- [ ] PR size reviewable (aim < 400 lines changed)

---

## Phase 2: Review Dimensions

Work through each dimension. Log every finding with severity before moving on.

### Dimension 1: Logic and Correctness

**Questions:** Implementation matches requirement? Off-by-one errors? Null/empty inputs handled? Boundary values tested? All conditional branches covered? Concurrent access safe? Algorithm terminates? Type coercions safe?

**Red flags:** Functions returning `undefined` on some paths; always-true/false conditions; mutating collection while iterating; missing `await` on async side effects.

### Dimension 2: Security

**Questions:** User input validated/sanitized? SQL parameterized? HTML escaped? No hardcoded secrets? Auth on every protected endpoint? Authorization (not just authentication) verified? File paths validated? Dependencies pinned, no known CVEs? PII not logged or in error messages? Rate limits on mutations?

**Red flags:** `query("... " + userId)` — injection; `innerHTML = userInput` — XSS; secrets logged; missing auth middleware; `require(userProvidedPath)` — traversal.

Cross-ref: `anti-patterns-catalog` Security section.

### Dimension 3: Performance

**Questions:** N+1 patterns? Unnecessary repeated expensive ops? Caching applied? Unbounded operations? Over-fetching fields? Indexes present? Blocking calls in async context? Large allocations in hot paths?

**Red flags:** DB query inside loop; `SELECT *` when 2 fields used; `setInterval` without throttle; full file in memory when streaming suffices.

Cross-ref: `anti-patterns-catalog` Performance section.

### Dimension 4: Maintainability

**Questions:** Names descriptive? Functions focused (< 30 lines)? Files focused (< 400 lines)? Deep nesting (> 3-4 levels)? Follows codebase conventions? Duplicated logic? Magic numbers? Commented-out code or orphaned TODOs? Appropriate abstraction level?

**Red flags:** `handleData`, `processInfo` names; `if (x === 2)` without explanation; 200-line function; deeply nested callbacks.

Cross-ref: `review-solid-clean-code`; `detect-code-smells`.

### Dimension 5: Error Handling

**Questions:** All error paths handled? No empty catch? Errors propagate correctly? User-friendly at UI boundary? Detailed at server log? External failures handled with retries/fallbacks? State restored on failure? Exceptions typed and specific? Error paths tested?

**Red flags:** `catch (e) {}` silent swallow; `catch (e) { console.log(e) }` with no recovery; `return null` hiding errors; `throw new Error("Something went wrong")` — no context; resources not closed on exception.

Cross-ref: `anti-patterns-catalog` Error Handling section.

### Dimension 6: Testing

**Questions:** Happy path tested? Edge cases (empty, null, boundary, max)? Error paths? Descriptive test names? Independent tests? Appropriate mocks (external deps only)? Coverage maintained? Integration tests for DB/API? Existing tests still pass? Testing behavior, not implementation?

**Red flags:** New feature with zero tests; asserting private methods; single test covering 12 scenarios; `expect(true).toBe(true)`.

Cross-ref: `anti-patterns-catalog` Testing section.

### Dimension 7: API Design

**Questions:** Consistent with codebase patterns? Parameter names/types consistent? Breaking changes? Backward compatibility? Return types consistent? Interface minimal (no leaked internals)? Optional params documented with defaults? Error responses consistent? HTTP status codes correct?

**Red flags:** Function returning different types based on state; inconsistent auth strategy; removing API field without deprecation; GET with side effects.

Cross-ref: `design-patterns-creational-structural` Facade; `refactor-simplifying-method-calls`.

---

## Phase 3: Severity Classification

| Severity | Definition | Action |
|----------|-----------|--------|
| **CRITICAL** | Security vuln, data loss, crash, regulatory violation | Block merge |
| **HIGH** | Logic error, race condition, missing auth, perf regression | Block merge |
| **MEDIUM** | Missing tests, unclear naming, missing error handling | Fix in PR or defer with agreement |
| **LOW** | Style inconsistency, minor naming, optional optimization | Suggest, do not block |
| **NIT** | Micro-style preferences | Prefix "nit:" — never block |

**Rule:** Any CRITICAL or HIGH = do not approve. MEDIUM = discuss before approval.

---

## Phase 4: Review Checklist

### Orientation and Logic
- [ ] PR goal understood; single concern; happy path + edge cases verified

### Security
- [ ] Inputs validated; no injection/XSS surface; no hardcoded secrets; auth verified

### Performance
- [ ] No N+1; no unbounded ops; caching where appropriate; no blocking in async

### Maintainability
- [ ] Descriptive names; no magic numbers; no deep nesting; no dead code; follows conventions

### Error Handling
- [ ] No silent catches; friendly user errors; detailed server logs; resources closed on failure

### Testing
- [ ] Happy + edge + error paths covered; independent, descriptive tests; coverage maintained

### API Design
- [ ] No breaking changes (or versioned); consistent return types; minimal interface; correct HTTP semantics

---

## Phase 5: Review Delivery

**Comment format:**
```
[SEVERITY] <file>:<line> — <finding>
Why: <1 sentence>
Fix: <specific action>
```

**Summary block:**
```
Reviewed: <PR title>
Findings: X CRITICAL, X HIGH, X MEDIUM, X LOW, X NIT
Decision: APPROVE / REQUEST CHANGES / COMMENT
```

---

## Common Findings

| Dimension | Red Flag | Severity | Fix |
|-----------|---------|----------|-----|
| Logic | Missing `await` on async side-effect | HIGH | — |
| Security | String concat into query | CRITICAL | Parameterize |
| Security | Missing auth on route | HIGH | Add middleware |
| Performance | DB query inside loop | HIGH | Batch/eager-load |
| Maintainability | 200-line function | MEDIUM | `refactor-composing-methods` |
| Error Handling | Empty `catch` | HIGH | Handle or propagate |
| Testing | New feature, zero tests | HIGH | Write tests first |
| API Design | Breaking field removal | HIGH | Version the API |

---

## Cross-References

| Topic | Skill |
|-------|-------|
| SOLID and clean code | `review-solid-clean-code` |
| Code smells | `detect-code-smells` |
| Refactoring techniques | `refactor-composing-methods`, `refactor-moving-features`, `refactor-generalization`, `refactor-simplifying-method-calls`, `refactor-organizing-data`, `refactor-simplifying-conditionals` |
| Design patterns | `design-patterns-behavioral`, `design-patterns-creational-structural` |
| Architecture-level review | `architectural-patterns` |
| Anti-patterns catalog | `anti-patterns-catalog` |
