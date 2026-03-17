---
name: pr-review-workflow
description: Use when starting a PR review and you need the end-to-end orchestration of all review skills into one complete workflow. This is the capstone skill that sequences every component skill into a principled, time-boxed process from PR load to verdict.
---

# PR Review Workflow — End-to-End Orchestrator

## Overview

This skill is the orchestrator for the full PR review library. Load it first. It tells you which skills to load at each phase, in what order, and why. A full review using this workflow takes 20–35 minutes for a typical PR. The workflow is designed to be risk-ordered, meaning you stop the review early if a blocker is found rather than wasting time on a PR that cannot be approved.

The library has 67 skills. You do not load all of them for every PR. This skill tells you which ones matter for the PR in front of you.

For a quick one-page reference that maps every review dimension to a deeper skill, see `review-cheat-sheet`. For a library of concrete end-to-end scenarios using this workflow, see `review-walkthroughs`.

## Quick Reference

| Phase | Time | Skills to Load |
|-------|------|----------------|
| 0: Pre-Review Setup | 2 min | `review-efficiency-patterns`, `review-automation-patterns` |
| 1: Triage | 3 min | `review-cheat-sheet` (Stop-the-PR section), `ai-generated-code-review` (if AI-assisted) |
| 2: Deep Review | 10–20 min | Language skill, `cross-language-review-heuristics`, `review-code-quality-process`, `security-patterns-code-review` (if security-sensitive) |
| 3: Calibrate | 3 min | `review-accuracy-calibration` |
| 4: Write Feedback | 5 min | `review-feedback-quality` |
| 5: Verdict | 1 min | — (decision criteria below) |

## Phase 0: Pre-Review Setup (2 min)

Before reading any code, establish context.

**Actions:**
1. Read the PR title and description. Understand the stated intent.
2. Check CI status. If the build is red, stop — do not review a failing PR.
3. Assess diff size. Count lines changed excluding auto-generated files (lock files, generated protos, vendored code).
4. Note the risk profile: Is this a security-sensitive area? Database migration? Public API change? High-traffic path?

**Load `review-efficiency-patterns`** to determine time allocation and review ordering based on diff size and risk signals. This skill provides heuristics for when to ask the author to split a PR, how to sequence which files to read first, and how to time-box each dimension.

**Load `review-automation-patterns`** to check what is already automated in CI for this repo. Avoid re-checking things that linters, type checkers, or security scanners already enforce. Focus your time on what automation cannot catch: logic, design, and context.

A quick pre-review checklist you can run mentally or as comments:

```
[ ] CI is green
[ ] Diff is under 400 lines of non-generated code
[ ] PR description explains the WHY, not just the WHAT
[ ] No auto-generated files inflating the diff count
[ ] Risk tier assigned: low / medium / high
```

**Output of this phase:** A mental model of the PR scope, a risk tier (low / medium / high), and an ordered list of which dimensions to review first.

## Phase 1: Triage (3 min)

Quick scan for CRITICAL blockers before investing in a full review.

**Load `review-cheat-sheet`** and run through the "Stop the PR" section. Check for:

- Hardcoded secrets in the diff (API keys, tokens, passwords)
- Obvious SQL injection or XSS (unescaped user input in SQL or HTML)
- Destructive DB operation without a rollback path
- Breaking API change with no migration or versioning
- Missing error handling on external calls

If any Stop-the-PR condition is true, leave a blocking comment and do not continue the review until resolved.

**If AI-generated or LLM-assisted code is detected** (indicated by PR description, commit message, or code style uniformity), load `ai-generated-code-review`. AI-generated code has distinct failure modes: hallucinated APIs, confident-looking but subtly wrong logic, test coverage that passes without actually exercising the code path.

**Output of this phase:** Either a blocking comment (and the review ends here) or confirmation that it is safe to proceed to Phase 2.

## Phase 2: Deep Review (10–20 min)

Systematic per-dimension review. Work through dimensions in risk order from `review-efficiency-patterns` — highest-risk dimensions first.

**Load the language-specific skill** for the primary language in the diff:

| Language | Skill |
|----------|-------|
| Go | `go-review-patterns` |
| Python | `python-review-patterns` |
| TypeScript / JavaScript | `typescript-review-patterns` |
| Rust | `rust-review-patterns` |
| Java | `java-review-patterns` |
| C++ | `cpp-review-patterns` |

**Load `cross-language-review-heuristics`** for signals that apply regardless of language: unclear variable names, overly long functions, missing abstraction boundaries, non-idiomatic patterns.

**Load `review-code-quality-process`** and work through each applicable dimension:

- Logic and correctness — does the code do what the ticket says?
- Error handling — every external call has an error branch
- Testing — new behavior has tests; bug fixes have regression tests
- API contract — backward compatible or versioned
- Architecture — fits existing layer boundaries; no new circular dependencies
- Performance — no N+1 queries; no unbounded operations
- Concurrency — shared mutable state is protected
- Observability — new paths emit structured logs and metrics
- Code smells — no Long Methods, Large Classes, Duplicate Code
- SOLID — see `review-solid-clean-code`

**For security-sensitive changes** (auth, payments, PII, public endpoints), load `security-patterns-code-review`. Also load `auth-authz-patterns` if the PR touches authentication or authorization logic.

**For database changes**, load `database-review-patterns` and `migration-patterns`.

**For API changes**, load `review-api-contract` and `graphql-grpc-api-patterns` as applicable.

**Output of this phase:** A raw list of findings, each labeled with severity (CRITICAL / HIGH / MEDIUM / LOW / NIT) and the dimension it belongs to.

## Phase 3: Calibrate (3 min)

Before writing feedback, apply the confidence model from `review-accuracy-calibration` to all findings.

**Load `review-accuracy-calibration`** and run each finding through the false positive reduction checklist:

- Is this finding based on missing context (the behavior may be correct but I cannot see why)?
- Is there an alternative interpretation of the code that makes it correct?
- Is this a style preference rather than a correctness issue?
- Is this pattern used consistently elsewhere in the codebase (suggesting intentional convention)?

For findings that survive the false positive filter, calibrate severity:

- Could this cause data loss, security breach, or production outage? → CRITICAL
- High confidence the code is wrong or will cause a defect? → HIGH
- Likely to cause maintenance burden or subtle bug? → MEDIUM
- Style, readability, minor improvement? → LOW / NIT

After calibration, consolidate duplicate findings (multiple instances of the same issue = one comment with examples).

A calibrated finding should read like this before you write the feedback:

```
Dimension:  Performance
Severity:   HIGH (calibrated from CRITICAL — not a production outage risk, but a 10x load spike risk)
Confidence: 90% — confirmed by reading the ORM call; it returns a slice, not a stream
Finding:    DB query buffers full result set; streaming claim in description is incorrect
Action:     Switch to cursor-based query or use db.QueryStream
```

**Output of this phase:** A final, calibrated list of findings with accurate severity labels.

## Phase 4: Write Feedback (5 min)

Convert calibrated findings into review comments.

**Load `review-feedback-quality`** for comment templates and tone guidance.

Principles from that skill:

- Every comment is actionable — it tells the author what to change and why
- Comments above LOW severity include a code example showing the fix when possible
- CRITICAL and HIGH comments are framed as blockers, not suggestions
- NIT comments are prefixed with "nit:" so authors can defer them
- Comments do not repeat what the diff already makes obvious

Write a summary comment at the top of the review that states: overall assessment, the most important issue the author needs to address, and whether the PR is approved.

**Output of this phase:** Review comments ready to submit.

## Phase 5: Verdict

Choose one of three outcomes based on your calibrated findings:

**Approve** when:
- No CRITICAL or HIGH findings remain
- All MEDIUM findings are either addressed or accepted as known trade-offs
- CI is green
- The change does what the description says

**Request Changes** when:
- One or more CRITICAL or HIGH findings exist
- The PR description does not match the implementation
- CI is red and the author has not acknowledged it
- The PR scope is too large to review safely (ask to split)

**Comment (no verdict)** when:
- You have questions that must be answered before you can evaluate correctness
- You are not the right reviewer for a specific dimension (e.g., security) and need to involve someone else
- The PR is a draft and the author has requested early feedback

## Walkthrough Example

This section shows a concrete TypeScript PR review using the full workflow.

### Context

PR title: "Add user export endpoint — GET /users/export"
PR description: "Exports all users in the account to CSV. Uses streaming to handle large datasets."
Diff size: 180 lines. CI is green. Language: TypeScript / Node.js.

### Phase 0 Output

Loaded `review-efficiency-patterns`. Risk profile: HIGH (data export endpoint — potential for data leak, PII exposure, performance issue on large datasets). Time allocation: 20 minutes. Review order: security first, then performance, then API contract, then error handling.

Loaded `review-automation-patterns`. ESLint and TypeScript strict mode are running in CI. No need to flag type errors or linting issues — they are already enforced.

### Phase 1 Output

Loaded `review-cheat-sheet` Stop-the-PR section.

Finding: The endpoint does not check authorization before querying the DB. A user from tenant A can call `/users/export` and receive data for all tenants. This is a CRITICAL data leak.

Blocking comment left. Review pauses here until the author adds tenant-scoped authorization.

Assume the author fixes the authorization issue and requests re-review.

### Phase 2 Output

Loaded `typescript-review-patterns`. Loaded `cross-language-review-heuristics`. Loaded `review-code-quality-process`.

Findings from deep review:

1. The streaming CSV writer does not handle the case where the DB query returns zero rows — it writes a header row and then closes the stream without error, which is correct. No issue.
2. The query `SELECT * FROM users WHERE account_id = ?` has no LIMIT. For accounts with 100k+ users this will load the entire result set into memory before streaming begins. The description says "uses streaming" but the implementation does not stream from the DB — it buffers the full result first. This is a HIGH performance issue.
3. The `Content-Disposition` header is set to `attachment; filename=users.csv` without a timestamp or unique identifier. If the user exports twice in the same browser session, the second file silently overwrites the first. This is LOW — it is a UX concern, not a defect.
4. No rate limiting on the endpoint. For a potentially expensive export operation this should be throttled. MEDIUM.

Loaded `security-patterns-code-review`. PII fields (email, phone) are included in the export without any audit log entry. MEDIUM — the export of PII should be logged for compliance.

### Phase 3 Output

Loaded `review-accuracy-calibration`. Ran each finding through the false positive filter.

Finding 2 (DB buffering): Confirmed. The code uses `await db.query(...)` which returns a resolved array, not a stream cursor. The description is misleading. HIGH confidence. Severity stays HIGH.

Finding 4 (rate limiting): Check whether rate limiting is handled at the API gateway layer. Looking at the infrastructure config — rate limiting is indeed applied at the gateway for all `/users/*` routes. This is a false positive. Downgraded to NIT (leave a note confirming gateway coverage).

Finding 5 (audit log): The codebase has an audit logging middleware for other sensitive endpoints. This endpoint does not use it. MEDIUM confidence — this is an oversight, not intentional. Severity stays MEDIUM.

Final calibrated findings:
- HIGH: DB query buffers full result set before streaming — fix to use cursor-based pagination or DB streaming
- MEDIUM: PII export not audit-logged
- LOW: filename has no timestamp
- NIT: Rate limiting confirmed at gateway — no action needed, added note for future reviewers

### Phase 4 Output

Loaded `review-feedback-quality`. Wrote comments:

HIGH comment on the streaming issue includes a before/after code example showing how to replace `await db.query(...)` with a cursor-based approach or use `db.queryStream(...)`.

MEDIUM comment on audit logging points to the existing `auditMiddleware` pattern used in `src/routes/payments.ts` and asks the author to apply the same pattern.

LOW comment on filename is framed as a suggestion, not a blocker.

NIT comment confirms gateway rate limiting and notes this for future reviewers.

### Phase 5 Verdict

Request Changes. One HIGH finding (DB buffering) must be resolved before approval. The audit logging MEDIUM should also be addressed. The LOW and NIT do not block.

## Cross-References — Full Review Skill Library

### Review Meta-Skills

| Skill | Purpose |
|-------|---------|
| `review-cheat-sheet` | Master one-page reference for all dimensions |
| `review-code-quality-process` | Per-dimension review process |
| `review-accuracy-calibration` | Confidence scoring and false positive reduction |
| `review-feedback-quality` | Writing actionable review comments |
| `review-efficiency-patterns` | Risk-based ordering and time-boxing |
| `review-automation-patterns` | Static analysis and CI gate integration |
| `cross-language-review-heuristics` | Universal signals across all languages |
| `ai-generated-code-review` | Reviewing LLM-assisted code |
| `review-solid-clean-code` | SOLID principles and clean code review |
| `review-api-contract` | API contract compatibility review |
| `review-metrics` | Measuring and improving review effectiveness |
| `review-walkthroughs` | End-to-end review scenarios with new skill stack |

### Language-Specific Review Guides

| Language | Skill |
|----------|-------|
| Go | `go-review-patterns` |
| Python | `python-review-patterns` |
| TypeScript / JavaScript | `typescript-review-patterns` |
| Rust | `rust-review-patterns` |
| Java | `java-review-patterns` |
| C++ | `cpp-review-patterns` |

### Security and Data Skills

| Skill | Purpose |
|-------|---------|
| `security-patterns-code-review` | Security vulnerability patterns |
| `auth-authz-patterns` | Authentication and authorization review |
| `data-validation-schema-patterns` | Input validation review |
| `database-review-patterns` | Database and query review |
| `migration-patterns` | Database migration review |

### Architecture and Design Skills

| Skill | Purpose |
|-------|---------|
| `architectural-patterns` | Layer boundaries and system design |
| `domain-driven-design-patterns` | Bounded contexts and aggregates |
| `microservices-resilience-patterns` | Circuit breakers, bulkheads, timeouts |
| `detect-code-smells` | Code smell identification |
| `design-patterns-creational-structural` | Creational and structural patterns |
| `design-patterns-behavioral` | Behavioral patterns |
| `dependency-injection-module-patterns` | DI and module boundaries |

### Performance and Infrastructure Skills

| Skill | Purpose |
|-------|---------|
| `performance-anti-patterns` | N+1, unbounded queries, blocking calls |
| `caching-strategies` | Cache invalidation and collision review |
| `concurrency-patterns` | Race conditions, deadlocks, shared state |
| `observability-patterns` | Structured logging and metrics |
| `distributed-tracing-patterns` | Trace propagation review |
| `container-kubernetes-patterns` | Container and K8s config review |
| `cicd-pipeline-patterns` | CI/CD pipeline review |
| `feature-flags-progressive-delivery` | Feature flag review |

### Domain-Specific Skills

| Skill | Purpose |
|-------|---------|
| `error-handling-patterns` | Error propagation and handling |
| `testing-patterns` | Test isolation, mocks, coverage |
| `graphql-grpc-api-patterns` | GraphQL and gRPC review |
| `api-rate-limiting-throttling` | Rate limiting review |
| `event-sourcing-cqrs-patterns` | Event sourcing and CQRS review |
| `message-queue-patterns` | Messaging and async workflow review |
| `data-pipeline-patterns` | Data pipeline review |
| `state-management-patterns` | Client-side state review |
| `real-time-communication-patterns` | WebSocket and SSE review |
| `multi-tenancy-patterns` | Tenant isolation review |
| `search-indexing-patterns` | Search and index review |
| `i18n-l10n-patterns` | Internationalization review |
| `code-documentation-patterns` | Documentation review |
