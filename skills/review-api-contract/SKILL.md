---
name: review-api-contract
description: Use when reviewing a REST API PR or design — covers resource naming, HTTP semantics, status codes, versioning, pagination, breaking vs non-breaking change classification, error response format, rate limiting, and idempotency, with a structured checklist for sign-off
---

# Review: API Contract

## Overview

This skill defines the review process for REST API changes — new endpoints, modified response shapes, versioning decisions, and breaking change assessment. Use it alongside `review-code-quality-process` when a PR exposes or modifies an HTTP API surface. Where code quality questions arise (auth middleware, error handling, testing), defer to that skill; this one focuses on the contract itself.

## When to Use

- Reviewing a PR that adds, modifies, or removes API endpoints
- Evaluating a proposed API design before implementation begins
- Assessing whether a change is breaking before it ships
- Auditing an existing API for consistency and correctness

---

## Dimension 1: Resource Naming

**Goal:** Verify that endpoint paths follow REST conventions and are consistent with existing routes.

**Questions:**
- Are resources named with nouns, not verbs? (`/users` not `/getUsers`)
- Are collection names plural? (`/orders` not `/order`)
- Are nested resources used only for genuine ownership relationships? (`/users/{id}/orders`)
- Are path parameters meaningful and stable identifiers? (prefer `userId` over positional index)
- Is casing consistent across all routes? (kebab-case preferred: `/payment-methods`)
- Are query parameters used for filtering, sorting, and field selection rather than resource identity?

**Red flags:**
- `/createOrder`, `/deleteUser`, `/fetchPayments` — verbs in paths
- `/user` for a collection endpoint — missing plural
- `/users/{userId}/addresses/{addressId}/lines/{lineId}` — nesting beyond two levels
- Mixing `/userId` and `/user_id` across routes

**Severity:** MEDIUM for naming inconsistency; HIGH if a new naming pattern is established that conflicts with existing routes (causes confusion for API consumers).

---

## Dimension 2: HTTP Methods and Semantics

**Goal:** Confirm each method is used according to its HTTP semantics.

**Questions:**
- Does GET only read? No state changes triggered by a GET request?
- Does POST create a new resource or trigger a non-idempotent action?
- Is PUT used for full replacement and PATCH for partial update?
- Does DELETE remove without requiring a request body?
- Are safe methods (GET, HEAD, OPTIONS) free of side effects?

**Red flags:**
- GET endpoint that writes to a database, sends an email, or charges a card
- POST used for everything — updates, deletes, reads — when REST methods are available
- DELETE that accepts a body to filter what gets deleted (unreliable across HTTP clients)
- PUT that only updates a subset of fields without acknowledging partial update semantics

**Severity:** HIGH for GET with side effects (breaks caching, breaks browser behavior, violates HTTP spec).

---

## Dimension 3: Status Codes

**Goal:** Confirm that status codes accurately describe the outcome of each request.

**Status code reference:** 200 OK (read/update with body), 201 Created (new resource + `Location` header), 204 No Content (delete/action with no body), 400 Bad Request (malformed input), 401 Unauthorized (no valid credentials), 403 Forbidden (valid credentials, insufficient permission), 404 Not Found, 409 Conflict (duplicate, optimistic lock), 422 Unprocessable Entity (business rule failure), 429 Too Many Requests (`Retry-After` required), 500 Internal Server Error (never expose stack traces).

**Questions:**
- Does a successful POST return 201 with a `Location` header pointing to the new resource?
- Does a successful DELETE return 204 (no body) or 200 (with confirmation body)?
- Is 400 vs 422 used consistently? (400 for malformed input, 422 for business rule violations)
- Is 401 vs 403 used correctly? (401 means "who are you?", 403 means "I know who you are, but no")
- Does the API ever return 200 with an error payload? (this is always wrong)

**Red flags:**
- `{ "success": false, "error": "not found" }` with HTTP 200
- 500 returned for client input errors (missing field, wrong type)
- 404 returned for authorization failures (leaks resource existence to unauthorized callers — use 403 or 404 consistently per security policy)
- 200 returned for empty collections (correct — return 200 with `[]`, not 404)

**Severity:** CRITICAL for 200 on error (breaks every HTTP client and monitoring tool); HIGH for 401/403 misuse (security implication).

---

## Dimension 4: Breaking vs Non-Breaking Changes

**Goal:** Classify every API change so consumers are protected from unexpected breakage.

### Breaking Changes — Block Without Versioning

| Change | Why It Breaks |
|--------|--------------|
| Remove a field from a response | Clients reading that field receive `undefined` / null pointer |
| Rename a field in a response | Same as removing the old field |
| Change a field type (string → integer) | Clients deserializing the old type fail |
| Remove an endpoint | Clients calling it receive 404 |
| Change an endpoint path | Clients using the old path receive 404 |
| Make an optional request field required | Existing clients omitting it now receive 400 |
| Change authentication strategy | Clients using old auth tokens fail |
| Change error response shape | Clients parsing the old shape fail silently or throw |
| Remove an enum value | Clients that sent or received that value break |
| Narrow an accepted value range | Previously valid inputs now rejected |

### Non-Breaking Changes — Safe to Ship

| Change | Why It Is Safe |
|--------|---------------|
| Add an optional field to a response | Existing clients ignore unknown fields |
| Add a new endpoint | Existing clients are unaffected |
| Add an optional query parameter | Existing clients omit it; default behavior unchanged |
| Add a new enum value | Existing clients must handle unknown enum values gracefully (document this expectation) |
| Deprecate a field (keep it, add deprecation notice) | Existing clients continue to work |
| Widen an accepted value range | Previously valid inputs still accepted |
| Change error message text | Acceptable if clients do not parse error message strings |

**Review questions:**
- Has the author identified every changed field in the response schema?
- For any removed or renamed field, is there a deprecation period with a documented migration path?
- For any type change, is backward-compatible serialization provided during transition?
- Is the PR description explicit about which changes are breaking and how consumers are notified?

**Severity:** CRITICAL for undisclosed breaking changes to a production API with external consumers; HIGH for internal APIs without a migration plan.

---

## Dimension 5: Versioning

**Goal:** Verify that breaking changes are isolated behind a version boundary.

**Common strategies:** URL path (`/v1/users`) — simple and cacheable but adds URL bloat; Request header (`Accept-Version: 2`) — clean URLs but harder to test; Query parameter (`?version=2`) — avoid, query params are for filtering not routing.

**Questions:**
- Does the project have an established versioning strategy? Is this PR consistent with it?
- If a breaking change is introduced, is it behind a new version segment?
- Is the old version maintained for the deprecation window (document the window if not established)?
- Is the versioning scope at the right level — endpoint-level vs API-level versioning?

**Red flags:**
- Breaking change shipped to `/v1/` with no new `/v2/` route
- Three different versioning strategies used across the same API
- No deprecation notice or sunset date on the old version

**Severity:** HIGH for breaking change without version boundary on a consumer-facing API.

---

## Dimension 6: Pagination

**Goal:** Verify that list endpoints are safe under large data volumes.

**Questions:**
- Does every list endpoint paginate? No endpoint should return unbounded results.
- Is the pagination strategy consistent across the API?
- For cursor-based pagination: is a stable, opaque cursor returned? Is `hasNextPage` present?
- For offset-based pagination: are `page`, `limit`, `total`, and `totalPages` returned?
- Is there a maximum page size enforced? (prevent `?limit=1000000`)
- Are `Link` headers included for cursor-based pagination (follows RFC 5988)?

**Cursor vs Offset trade-offs:**

| Aspect | Cursor | Offset |
|--------|--------|--------|
| Consistent under insertions | Yes | No (items shift) |
| Allows jumping to page N | No | Yes |
| Performance on large tables | Better (index-friendly) | Degrades with high offset |
| Implementation complexity | Higher | Lower |

**Red flags:**
- `GET /orders` with no pagination parameters — entire table returned
- `limit` parameter accepted but no server-side maximum enforced
- Offset pagination on a frequently-updated collection (stale/duplicate items in results)
- Inconsistent field names: `page` on one endpoint, `pageNumber` on another

**Severity:** HIGH for missing pagination on a collection that can grow unbounded (denial of service risk).

---

## Dimension 7: Error Response Format

**Goal:** Confirm error responses follow a consistent, parseable envelope.

**Recommended envelope:**
```json
{
  "error": {
    "code": "VALIDATION_FAILED",
    "message": "The request body is invalid.",
    "details": [
      { "field": "email", "issue": "Must be a valid email address." }
    ],
    "requestId": "req_abc123"
  }
}
```

**Questions:**
- Do all error responses follow the same shape?
- Is `code` a machine-readable string constant? (not a human sentence — clients switch on `code`)
- Is `message` human-readable and safe to display? (no stack traces, no internal paths)
- Are field-level validation errors included in `details` so clients can surface them per-field?
- Is a `requestId` or `traceId` included for support debugging?
- Is the Content-Type `application/json` even for error responses?

**Red flags:**
- Plain text error body: `HTTP 400 — "bad input"` (unquoted string, not JSON)
- Stack trace in the response body in any environment
- Error shape differs between endpoints — some use `{ error: "..." }`, others `{ message: "..." }`
- `code` field contains an integer rather than a named constant (fragile — integers have no meaning)

**Severity:** HIGH for stack traces in production (leaks implementation details); MEDIUM for inconsistent error shapes.

---

## Dimension 8: Rate Limiting and Idempotency

**Goal:** Verify that the API is resilient to retry storms and volume abuse.

**Rate limiting questions:**
- Is a 429 status returned when the rate limit is exceeded?
- Is the `Retry-After` header included? (seconds or HTTP date until reset)
- Are `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset` headers present?
- Are limits applied per user, per IP, or per API key? Is this appropriate for the endpoint?

**Idempotency questions:**
- Are PUT and DELETE endpoints idempotent? (calling twice produces same state as calling once)
- For POST endpoints that trigger side effects (payments, emails), is an idempotency key supported?
- Is the idempotency key passed via `Idempotency-Key` header (standard) or a request body field?
- Is the idempotency window documented? (24 hours is common)

**Red flags:**
- No 429 response — rate limit silently drops requests or returns 500
- Retry of a payment POST charges the card twice (missing idempotency)
- DELETE that fails on second call with 404 when it should return 204 (not truly idempotent response)

**Severity:** HIGH for missing idempotency on financial or state-mutating POST endpoints.

---

## API Contract Review Checklist

Use before approving any PR that adds or modifies API endpoints.

### Resource Naming
- [ ] Paths use nouns, not verbs
- [ ] Collection paths are plural
- [ ] Nesting does not exceed two levels
- [ ] Casing is consistent with existing routes

### HTTP Semantics
- [ ] GET endpoints have no side effects
- [ ] POST, PUT, PATCH, DELETE methods used per HTTP specification
- [ ] Safe methods are truly safe (no writes, no emails, no charges)

### Status Codes
- [ ] 200/201/204 used correctly for successes
- [ ] 400 vs 422 distinction applied consistently
- [ ] 401 vs 403 applied correctly
- [ ] No 200 with an error body anywhere in the diff

### Breaking Changes
- [ ] Every changed response field is identified
- [ ] No breaking changes are shipped without a version boundary or migration plan
- [ ] Any deprecated fields are marked and retain their old behavior

### Versioning
- [ ] Breaking changes are behind a new version segment
- [ ] Versioning strategy is consistent with the rest of the API
- [ ] Old version deprecation window is stated

### Pagination
- [ ] Every new list endpoint includes pagination
- [ ] Maximum page size is enforced server-side
- [ ] Pagination field names are consistent with existing endpoints

### Error Format
- [ ] All error responses use the standard envelope
- [ ] `code` is a named machine-readable constant
- [ ] No stack traces in any response
- [ ] `requestId` or `traceId` included

### Rate Limiting and Idempotency
- [ ] 429 returned with `Retry-After` on limit exceeded
- [ ] POST endpoints with side effects support idempotency keys
- [ ] PUT and DELETE are idempotent in both behavior and response

### OpenAPI / Schema Contract
- [ ] Schema changes reviewed via diff (e.g., `openapi-diff`, `oasdiff`)
- [ ] No required fields added to existing request bodies (breaking)
- [ ] No response field types narrowed or changed (breaking)
- [ ] New required response fields only added with default values
- [ ] Nullable fields not silently changed to non-nullable (breaking)
- [ ] Enum values not removed from existing fields (breaking)
- [ ] `additionalProperties` handling is explicit
- [ ] Schema descriptions updated for new/changed fields

### GraphQL Contract
- [ ] Fields deprecated with `@deprecated(reason: "...")` before removal
- [ ] Deprecated fields kept for at least one release cycle
- [ ] Non-null (`!`) not added to existing return fields (breaking)
- [ ] Input types not made stricter (adding required input field = breaking)
- [ ] New queries/mutations follow existing naming conventions
- [ ] Resolver N+1 patterns addressed with DataLoader or batching
- [ ] Pagination uses Relay-style cursor connections for lists

---

## Cross-References

| Topic | Related Skill |
|-------|--------------|
| Full code review process across all dimensions | `review-code-quality-process` |
| API Design dimension (interfaces, return types, backward compat) | `review-code-quality-process` → Dimension 7 |
| Architecture-level API gateway, service boundary decisions | `architectural-patterns` |
| Anti-patterns in security, performance, and error handling | `anti-patterns-catalog` |
