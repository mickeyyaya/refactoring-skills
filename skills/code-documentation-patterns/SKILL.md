---
name: code-documentation-patterns
description: Use when writing or reviewing documentation — covers Architecture Decision Records (ADR), API documentation (OpenAPI/AsyncAPI/JSDoc/docstrings), README and runbook standards, inline comments, technical debt registers, and documentation anti-patterns with concrete examples and red flags across TypeScript, Python, Java, and Go
---

# Code Documentation Patterns

## Overview

Stale docs erode trust, misleading comments introduce bugs, and undocumented architectural decisions get re-litigated every six months. Use this guide to write documentation that stays accurate, helps future contributors, and scales with the codebase.

**When to use:** Adding a new public API, recording an architectural decision, onboarding a new team member, reviewing PRs for documentation completeness, or auditing a codebase for documentation health.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Architecture Decision Record | Document context, decision, and consequence in a lightweight file | Decision made verbally, never written down; team re-debates the same choice |
| API Documentation (OpenAPI/AsyncAPI) | Machine-readable contract that doubles as human-readable reference | Docs generated from code only, never from intent; drifts from actual behavior |
| JSDoc / Docstrings | Inline structured comments on public interfaces | Missing param types, stale return descriptions, no examples for complex behavior |
| README Standards | Orientation doc covering purpose, setup, usage, and runbook | README last updated two major versions ago; no local-run instructions |
| Inline Documentation | Explain *why*, not *what*; annotate non-obvious decisions | Comments restate the code; intent buried; nothing explains the workaround |
| Technical Debt Register | Intentional debt tracked with owner, cost, and due date | `// TODO` comments with no date, owner, or ticket reference |
| Documentation Anti-Patterns | Stale docs, misleading comments, commented-out code | Committed code blocks that "might be useful later" |

---

## Patterns in Detail

### 1. Architecture Decision Records (ADR)

An ADR captures the context, decision, and consequence of a significant technical choice. It is the single artifact that prevents a future engineer from re-opening a settled debate without understanding why it was settled.

**Red Flags:**
- Major technology or design choices exist only in Slack history or someone's memory
- The codebase has unexplained structural choices that contradict newer team norms
- New team members repeatedly ask "why do we do it this way?"
- A decision was reversed without any written record of why the previous approach was rejected

**Canonical ADR structure — context, decision, consequence:**

```markdown
# ADR-0042: Use PostgreSQL over MongoDB for the orders service

## Status
Accepted — 2024-11-15

## Context
The orders service stores structured relational data (order → line items → products → users).
We initially used MongoDB for flexibility during prototyping.
As query patterns became clear, we found ourselves reconstructing joins in application code
and fighting schema drift across environments.
The team has strong SQL expertise; no team member has production MongoDB experience.

## Decision
Migrate orders storage to PostgreSQL.
All joins are expressed in SQL; application code handles no manual join logic.
Use transactions for multi-table writes (order + line items).

## Consequence
- Positive: Query complexity moves to SQL where it belongs; simpler application code
- Positive: ACID transactions eliminate the partial-write bug class we saw in MongoDB
- Negative: Migration requires a one-time downtime window and data transform script
- Negative: Horizontal write scaling is harder than MongoDB's sharding model
  (accepted: orders volume does not require sharding at current scale)

## Alternatives Considered
- Keep MongoDB and enforce a schema via Mongoose — rejected: does not fix join complexity
- Use DynamoDB — rejected: team has no DynamoDB experience; access patterns not a good fit
```

**File placement convention:**

```
docs/
  decisions/
    0001-use-postgres-for-orders.md
    0042-adopt-opentelemetry.md
    README.md   ← index listing all ADRs with one-line summaries
```

**Tooling — `adr-tools` CLI:**

```bash
# Initialize ADR directory
adr init docs/decisions

# Create a new ADR (auto-increments number)
adr new "Use OpenTelemetry for distributed tracing"

# Supersede an old ADR
adr new -s 12 "Replace custom metrics with Prometheus"
```

Cross-reference: `system-design-patterns` — use ADRs to document trade-offs when choosing between design alternatives.

---

### 2. API Documentation (OpenAPI, AsyncAPI, JSDoc, Docstrings)

**Red Flags:**
- OpenAPI spec exists but diverges from actual route behavior (never validated in CI)
- Parameters documented as optional when the server rejects missing values
- No examples for complex request/response shapes
- AsyncAPI events undocumented — consumers must read producer source code to understand message shapes
- JSDoc `@param` types disagree with TypeScript types in the same file
- Docstrings copy the function name verbatim and add nothing

**OpenAPI — document intent, not just shape:**

```yaml
# BEFORE — technically valid but useless
paths:
  /orders/{id}:
    get:
      summary: Get order

# AFTER — explains behavior, error cases, and authentication requirements
paths:
  /orders/{id}:
    get:
      summary: Retrieve a single order by ID
      description: |
        Returns the full order with all line items.
        Requires the caller to own the order or have the `admin` role.
        Returns 404 for orders that exist but belong to another user (avoids enumeration).
      security:
        - bearerAuth: []
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
            format: uuid
          description: Unique identifier of the order
      responses:
        "200":
          description: Order found
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Order"
              examples:
                standard:
                  summary: Typical order with two line items
                  value:
                    id: "a1b2c3d4-..."
                    status: "shipped"
                    items: [{ sku: "WIDGET-1", qty: 2 }]
        "404":
          description: Order not found or caller does not own it
        "401":
          description: Missing or invalid bearer token
```

**AsyncAPI — document event-driven contracts:**

```yaml
asyncapi: "2.6.0"
info:
  title: Order Events
  version: "1.0.0"
channels:
  order.placed:
    description: Published when a new order is successfully created and payment captured
    subscribe:
      message:
        name: OrderPlaced
        payload:
          type: object
          required: [orderId, userId, placedAt, totalCents]
          properties:
            orderId:
              type: string
              format: uuid
            userId:
              type: string
              format: uuid
            placedAt:
              type: string
              format: date-time
            totalCents:
              type: integer
              description: Total in smallest currency unit (e.g., cents for USD)
```

**JSDoc — TypeScript:**

```typescript
/**
 * Applies a percentage discount to a cart total.
 *
 * Rounds down to the nearest cent to avoid floating-point accumulation errors.
 * Does NOT apply if the discount would reduce the total below the minimum order
 * value ({@link MIN_ORDER_CENTS}); returns the original total in that case.
 *
 * @param totalCents - Pre-tax cart total in cents (must be >= 0)
 * @param discountPct - Discount percentage as a decimal (0.1 = 10%)
 * @returns Discounted total in cents, or original total if below minimum
 *
 * @example
 * applyDiscount(1000, 0.1)  // 900
 * applyDiscount(50, 0.5)    // 50 (below MIN_ORDER_CENTS, no discount applied)
 */
export function applyDiscount(totalCents: number, discountPct: number): number {
  const discounted = Math.floor(totalCents * (1 - discountPct));
  return discounted >= MIN_ORDER_CENTS ? discounted : totalCents;
}
```

**Python docstrings — Google style:**

```python
def apply_discount(total_cents: int, discount_pct: float) -> int:
    """Apply a percentage discount to a cart total.

    Rounds down to the nearest cent. Does not apply the discount if the result
    would fall below MIN_ORDER_CENTS; returns the original total in that case.

    Args:
        total_cents: Pre-tax cart total in cents. Must be >= 0.
        discount_pct: Discount as a decimal fraction (0.1 == 10%).

    Returns:
        Discounted total in cents, or the original total if applying the
        discount would violate the minimum order constraint.

    Raises:
        ValueError: If total_cents is negative or discount_pct is outside [0, 1).

    Examples:
        >>> apply_discount(1000, 0.1)
        900
        >>> apply_discount(50, 0.5)
        50
    """
```

**CI validation — prevent doc drift:**

```yaml
# .github/workflows/api-docs.yml
- name: Validate OpenAPI spec
  run: npx @redocly/cli lint docs/openapi.yaml

- name: Check spec matches implementation
  run: npx openapi-diff docs/openapi.yaml docs/openapi.generated.yaml
```

---

### 3. README Standards and Onboarding / Runbook Documentation

A README is the first thing a new engineer reads. It must answer five questions within two minutes: what does this do, how do I run it locally, how do I deploy it, what do I do when it breaks, and where do I find more?

**Red Flags:**
- README has not been updated since the initial commit
- "Just run `npm start`" — no mention of required environment variables
- No onboarding section; new engineers shadow a senior for a full day to get running
- Runbook lives in someone's Notion page, not in the repo alongside the code it describes
- Troubleshooting section contains one line: "Check the logs"

**Canonical README structure:**

```markdown
# Orders Service

One sentence: manages the full lifecycle of customer orders from placement to fulfillment.

## Quick Start (local development)

Prerequisites: Node 20+, Docker (for Postgres), AWS CLI configured for dev account.

    git clone git@github.com:acme/orders-service.git
    cd orders-service
    cp .env.example .env          # fill in values from 1Password > "Orders Dev"
    docker compose up -d postgres
    npm install
    npm run db:migrate
    npm run dev                   # starts on http://localhost:3000

## Environment Variables

| Variable             | Required | Description                              |
|----------------------|----------|------------------------------------------|
| DATABASE_URL         | yes      | Postgres connection string               |
| STRIPE_SECRET_KEY    | yes      | Stripe API key (use test key locally)    |
| RECOMMENDATION_URL   | no       | Recommendations service URL; degraded if absent |

## Running Tests

    npm test              # unit + integration (requires docker compose up -d postgres)
    npm run test:e2e      # end-to-end (requires full docker compose stack)

## Deployment

Merged PRs to `main` deploy automatically via GitHub Actions to staging.
Production deploy: create and push a version tag (`git tag v1.x.x && git push --tags`).
Deployment status: https://github.com/acme/orders-service/actions

## Runbook

### Service is returning 500s

1. Check recent deploys: `gh run list --workflow deploy.yml`
2. Query error rate: `kubectl logs -l app=orders-service --since=10m | grep ERROR`
3. Check database connectivity: `kubectl exec -it deploy/orders-service -- npm run db:check`
4. If DB unavailable, escalate to #on-call-infra; otherwise roll back last deploy

### Database migrations are failing

1. Check migration state: `npm run db:migrate:status`
2. Look for locks: `SELECT * FROM pg_stat_activity WHERE wait_event_type = 'Lock';`
3. If locked, identify and terminate the blocking PID after confirming it is safe to do so

## Architecture

See [docs/decisions/](./docs/decisions/) for ADRs.
High-level diagram: [docs/architecture.png](./docs/architecture.png)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).
```

**Onboarding checklist (keep in repo at `docs/onboarding.md`):**

```markdown
# Onboarding Checklist — Orders Service

Day 1:
- [ ] Clone the repo and complete Quick Start above
- [ ] Run the test suite — all tests should pass before you write a line
- [ ] Read the three most recent ADRs in docs/decisions/
- [ ] Shadow one on-call rotation shift (read-only)

Week 1:
- [ ] Complete a "good first issue" ticket
- [ ] Add your name to docs/team.md with your area of ownership
- [ ] Review one PR per day to learn patterns
```

---

### 4. Inline Documentation — What to Document and What Not To

**Red Flags:**
- Comment restates the code: `i++ // increment i`
- No comment on a non-obvious algorithm or business rule
- Commented-out code blocks committed to the repository
- `// TODO` with no owner, no date, and no ticket reference
- A workaround with no comment explaining why it is necessary

**Document the WHY, not the WHAT:**

```typescript
// WRONG — restates the code, adds noise
// Check if user is active
if (user.status === 'active') { ... }

// WRONG — "might be useful later" dead code
// const legacyTotal = items.reduce((sum, i) => sum + i.price, 0);

// CORRECT — explains non-obvious business rule
// Stripe requires amounts in cents; multiply before rounding to avoid
// floating-point truncation errors that accumulate across line items.
const chargeCents = Math.round(orderTotal * 100);

// CORRECT — explains the workaround and when it can be removed
// WORKAROUND: Stripe webhook retries can deliver duplicate order.placed events
// within the same 5-second window before our idempotency key TTL takes effect.
// This extra DB check prevents double-charging. Remove when PLAT-4421 is resolved.
const existing = await orderRepo.findByStripePaymentIntent(paymentIntentId);
if (existing) return existing;
```

**What to always document:**
- Non-obvious algorithms (link to the paper or ticket where the algorithm was chosen)
- Business rules that are not self-evident from the domain
- Intentional workarounds with a reference to the root cause
- Security-sensitive sections (why a particular sanitization or validation is required)
- Performance-sensitive sections (why this approach was chosen over a simpler one)

**What NOT to document:**
- Code that already reads like prose (`createUser`, `validateEmail`, standard CRUD)
- Every parameter in a function with a descriptive name and a type annotation
- Temporary scaffolding (delete it; do not comment it out)

---

### 5. Technical Debt Register — Intentional Debt Tracking

Technical debt is not a failure; undocumented, unowned technical debt is. A debt register turns implicit liabilities into explicit decisions with owners and due dates.

**Red Flags:**
- `// TODO` scattered through the codebase with no ticket references
- Known performance bottlenecks that "everyone knows about" but appear nowhere in writing
- A workaround was introduced two years ago and the ticket to clean it up was never created
- Intentional debt was taken on to hit a launch deadline but never recorded
- No review cadence for the debt register — items accumulate indefinitely

**Debt register format (`docs/technical-debt.md`):**

```markdown
# Technical Debt Register

Last reviewed: 2024-12-01 | Owner: Engineering lead

## Active Items

| ID | Description | Introduced | Owner | Cost | Ticket | Due |
|----|-------------|-----------|-------|------|--------|-----|
| TD-001 | Orders search uses full table scan; added a `LIKE` query for MVP. Will degrade beyond 500k orders. | 2024-09-10 | @alice | High — will require emergency index migration at scale | PLAT-1234 | 2025-Q1 |
| TD-002 | PDF generation runs synchronously in the request handler. P99 latency is 4s. | 2024-10-15 | @bob | Medium — user-visible latency; no data risk | PLAT-1890 | 2025-Q2 |
| TD-003 | Auth token validated on every middleware call; result not cached. | 2024-11-01 | @carol | Low — adds ~2ms per request | PLAT-2001 | Backlog |

## Resolved Items

| ID | Description | Resolved | PR |
|----|-------------|----------|----|
| TD-000 | MongoDB used instead of Postgres for orders. | 2024-11-15 | #482 |
```

**Intentional debt annotation in code — reference the register:**

```typescript
// TECH-DEBT TD-002: PDF generation is synchronous here.
// Ticket: https://github.com/acme/orders/issues/1890
// Cost: user-visible 4s P99 latency; no data correctness risk.
// Fix: move to async job queue (BullMQ) before Q2 2025.
const pdfBuffer = await generateInvoicePdf(order);
```

**Go:**
```go
// TECH-DEBT TD-001: Full table scan on order search.
// Replace with partial index on (customer_id, created_at) — see PLAT-1234.
rows, err := db.QueryContext(ctx,
    `SELECT * FROM orders WHERE customer_id = $1 AND status LIKE $2`, id, "%"+status+"%")
```

---

### 6. Documentation Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Stale Documentation** | Docs describe a previous version of the system | Co-locate docs with code; add doc-update step to PR checklist; run `linkcheck` in CI |
| **Misleading Comments** | Comment says one thing, code does another | Delete the comment and rewrite it from scratch; trust types and tests over comments |
| **Commented-Out Code** | Disabled code committed "just in case" | Delete it; git history is the undo stack |
| **Wall-of-Text ADR** | Decision recorded but context is a 10-page essay | Timebox ADR writing to 30 minutes; link to external research rather than inlining it |
| **Auto-Generated Noise** | Every getter/setter has a JSDoc that says "Gets X" / "Sets X" | Only document non-obvious behavior; generated docs are clutter |
| **TODO Graveyard** | File has 20 `// TODO` comments, half from 3 years ago | Create tickets for valid items; delete the rest |
| **Secret Inline Comments** | `// password is hardcoded until ENV is set up` | Never commit secrets or workarounds that bypass security controls |
| **Over-Documented Internals** | Private helper functions have more comments than the public API | Document public interfaces thoroughly; keep private code concise |

**Stale doc detection in CI:**

```yaml
# Warn when a source file changes without a corresponding doc update
- name: Check doc freshness
  run: |
    CHANGED=$(git diff --name-only origin/main...HEAD | grep -E '\.(ts|go|py)$')
    DOCS_CHANGED=$(git diff --name-only origin/main...HEAD | grep -E '\.(md)$')
    if [ -n "$CHANGED" ] && [ -z "$DOCS_CHANGED" ]; then
      echo "WARNING: source files changed but no .md files updated"
      echo "Consider updating relevant docs or ADRs"
    fi
```

**Removing commented-out code — TypeScript example:**

```typescript
// WRONG — commented-out code in production codebase
// async function legacyCharge(amount: number) {
//   return stripe.charges.create({ amount, currency: 'usd' });
// }
async function charge(amount: number, customerId: string) {
  // Use PaymentIntents API (replaces legacy Charges API — see ADR-0031)
  return stripe.paymentIntents.create({ amount, currency: 'usd', customer: customerId });
}

// CORRECT — just the current implementation; git log has the legacy version
async function charge(amount: number, customerId: string) {
  return stripe.paymentIntents.create({ amount, currency: 'usd', customer: customerId });
}
```

---

### 7. Code Comments Best Practices

Good comments are maintenance assets. Bad comments are maintenance liabilities. Apply these rules before adding any comment.

**Rules:**
1. If you can make the code self-documenting (better names, extracted function), do that first
2. Comment the *why* (intent, constraint, context) — never the *what* (restatement of code)
3. Every workaround comment must include: why it exists, what breaks without it, and a ticket to remove it
4. Avoid inline `// TODO` without a ticket reference; create the ticket, link it
5. Security-sensitive logic must always have a comment explaining the threat being mitigated

**Comment quality gradient:**

```python
# LEVEL 0 — noise (delete it)
x = x + 1  # increment x

# LEVEL 1 — restates code (delete it)
# Loop through all users
for user in users:
    ...

# LEVEL 2 — acceptable (names alone aren't enough to convey domain meaning)
# ISO 8601 format required by the downstream billing system
formatted_date = event_time.strftime("%Y-%m-%dT%H:%M:%SZ")

# LEVEL 3 — excellent (explains non-obvious invariant and cross-system constraint)
# Stripe webhook events can arrive out of order. We process idempotently and
# skip events whose sequence number is less than the last-processed sequence
# to prevent reversing a later state update with an earlier one.
# See: https://stripe.com/docs/webhooks/best-practices#event-ordering
if event.sequence <= last_sequence:
    logger.info("skipping out-of-order webhook", event_id=event.id)
    return
```

**Annotation conventions (team-wide consistency matters):**

```typescript
// TODO(alice, PLAT-1234): Replace with streaming response once infra supports HTTP/2
// FIXME(bob, PLAT-5678): Off-by-one on page boundaries — repro in test_pagination.ts
// HACK: Stripe SDK v4 does not expose the raw idempotency key; parse from headers
// NOTE: This timeout is deliberately longer than the SLA to give downstream time to drain
// WORKAROUND(PLAT-9012): Remove after Node.js 22 LTS is adopted (fixes crypto.webcrypto bug)
```

---

## Cross-References

- `error-handling-patterns` — inline annotation for retry logic and workaround comments
- `system-design-patterns` — ADRs record the architectural trade-offs captured in system design
- `review-code-quality-process` — documentation completeness checklist for PR review
- `detect-code-smells` — "Comment Smell": comments that explain bad code are a signal to refactor, not document
