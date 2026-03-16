---
name: observability-patterns
description: Use when reviewing code for observability correctness — covers Structured Logging, Log Levels, Distributed Tracing, Metrics (counters/gauges/histograms), Health Checks, Alerting, Correlation IDs, and Audit Trails with red flags and fix strategies across TypeScript, Python, Java, and Go
---

# Observability Patterns for Code Review

## Overview

Unobservable systems fail silently. Use this guide during code review to catch observability hazards: missing correlation IDs, cardinality explosions, phantom health checks, and more.

**When to use:** Reviewing services with external calls, background jobs, or HTTP/gRPC APIs; evaluating logging, metrics, tracing; code touching distributed async flows or admin operations.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Structured Logging | JSON with consistent context fields | `console.log()` with string concat, no correlation ID |
| Log Levels | DEBUG/INFO/WARN/ERROR by severity | Everything at INFO, ERROR for non-errors |
| Distributed Tracing | Trace ID across service boundaries | Missing trace context in headers, no spans on external calls |
| Metrics | Counters/gauges/histograms on critical paths | No metrics on critical paths, cardinality explosion |
| Health Checks | Liveness vs. Readiness probes | Always returns 200, dependency check in liveness |
| Alerting | Symptom-based (SLO breach), not cause-based | Alert on every error, no SLO alert |
| Correlation IDs | Request ID through all async hops | Context lost at async boundary, no requestId in errors |
| Audit Trails | Immutable who/what/when record | No audit for admin ops, mutable audit records |

---

## Patterns in Detail

### 1. Structured Logging

**Red Flags:** Unstructured `console.log` with string concat; PII in fields; no `requestId`; log-and-throw causing duplicates.

```typescript
// BEFORE — unstructured, no context
console.log("Failed to process order for user " + userId + ": " + err.message);

// AFTER — structured JSON, context-rich
logger.error("order.process.failed", {
  requestId: ctx.requestId, userId, orderId: order.id,
  durationMs: Date.now() - startMs,
  error: { message: err.message, code: err.code },
});
```

```go
// Go — zap (zero allocation)
logger.Error("order.process.failed",
    zap.String("requestId", ctx.RequestID), zap.String("userId", userID),
    zap.Error(err), zap.Duration("duration", time.Since(start)))
```

---

### 2. Log Levels

**Red Flags:** Everything at INFO; `logger.error()` for expected conditions; no WARN usage; secrets in DEBUG logs.

| Level | When | Example |
|-------|------|---------|
| DEBUG | Internals, dev only | SQL text, serialized payloads |
| INFO | Normal business events | Order created, user login |
| WARN | Unexpected but recoverable | Retry #2 of 3, elevated cache miss |
| ERROR | Failed, human action needed | Payment declined, DB connection lost |

```java
// BEFORE — wrong levels
log.info("Payment service unavailable, retrying...");
log.error("User not found: " + userId);

// AFTER
log.warn("payment.service.retry", Map.of("attempt", attempt, "maxAttempts", 3));
log.info("user.not_found", Map.of("userId", userId));
```

---

### 3. Distributed Tracing

**Red Flags:** Outgoing calls missing `traceparent` header; no child spans on external calls; traceId regenerated downstream; async tasks without trace context.

```typescript
// BEFORE — black box in traces
const result = await fetch("http://inventory-svc/check");

// AFTER — span wraps call, context propagated
const span = tracer.startSpan("inventory.check", { attributes: { "order.id": orderId } });
const headers: Record<string, string> = {};
propagation.inject(context.active(), headers);
try { return await fetch(inventoryUrl, { headers }); }
catch (err) { span.recordException(err as Error); span.setStatus({ code: SpanStatusCode.ERROR }); throw err; }
finally { span.end(); }
```

---

### 4. Metrics

**Red Flags:** No metrics on handlers/consumers/critical ops; high-cardinality labels (`userId`, `orderId`); gauge where counter correct; count without latency.

| Type | Measures | Example |
|------|----------|---------|
| Counter | Monotonic total | `http_requests_total`, `errors_total` |
| Gauge | Point-in-time snapshot | `queue_depth`, `active_connections` |
| Histogram | Distribution + percentiles | `http_request_duration_seconds` |

```typescript
const requestDuration = new Histogram({
  name: "http_request_duration_seconds",
  labelNames: ["method", "route"],  // low cardinality
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1],
});
const end = requestDuration.startTimer({ method: req.method, route: req.route.path });
try { return await handle(req); } finally { end(); }
```

---

### 5. Health Checks

**Red Flags:** Single endpoint always returning 200; DB check in liveness probe; no timeout on dependency probes; health endpoint requires auth.

```typescript
// BEFORE — always 200, DB in wrong probe
app.get("/health", async (_req, res) => { await db.query("SELECT 1"); res.json({ ok: true }); });

// AFTER — split probes
app.get("/health/live", (_req, res) => res.json({ status: "alive" }));
app.get("/health/ready", async (_req, res) => {
  const checks = await Promise.allSettled([
    withTimeout(db.query("SELECT 1"), 2000), withTimeout(redis.ping(), 1000),
  ]);
  const failed = checks.filter(c => c.status === "rejected");
  res.status(failed.length ? 503 : 200).json({ status: failed.length ? "not_ready" : "ready" });
});
```

---

### 6. Alerting Patterns

**Red Flags:** Alert on every error (fatigue); no SLO breach alert; zero threshold (fires in staging); no runbook link.

```yaml
# WRONG — cause-based
- alert: DatabaseSlowQueries
  expr: mysql_slow_queries_total > 10

# CORRECT — symptom-based SLO
- alert: OrderServiceHighErrorRate
  expr: |
    rate(http_requests_total{service="order-svc",status_code=~"5.."}[5m])
    / rate(http_requests_total{service="order-svc"}[5m]) > 0.01
  for: 2m
  annotations:
    summary: "Error rate > 1% for 2 minutes"
    runbook: "https://runbooks.internal/order-svc-errors"
```

---

### 7. Correlation IDs

**Red Flags:** `requestId` not propagated into async callbacks/queues; error responses missing `requestId`; ID regenerated downstream; not forwarded in outgoing headers.

```typescript
export const requestContext = new AsyncLocalStorage<{ requestId: string }>();

app.use((req, _res, next) => {
  const requestId = (req.headers["x-request-id"] as string) ?? uuidv4();
  requestContext.run({ requestId }, next);
});

// Error handler includes requestId for traceability
app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  const ctx = requestContext.getStore();
  res.status(500).json({ error: "Internal error", requestId: ctx?.requestId });
});
```

```java
// Java — MDC
MDC.put("requestId", Optional.ofNullable(request.getHeader("X-Request-Id"))
    .orElse(UUID.randomUUID().toString()));
try { chain.doFilter(req, res); } finally { MDC.clear(); }
```

---

### 8. Audit Trails

**Red Flags:** No audit for admin ops (delete user, change role); audit records subject to DELETE/UPDATE; before/after state not captured; audit write in same transaction as mutation.

```typescript
async function changeUserRole(actor: Actor, targetUserId: string, newRole: Role, ctx: RequestContext) {
  const before = await userRepo.findById(targetUserId);
  await userRepo.updateRole(targetUserId, newRole);
  const after = await userRepo.findById(targetUserId);
  await auditLog.append({
    id: uuidv4(), ts: new Date().toISOString(),
    actor: { id: actor.id, role: actor.role }, action: "user.role.changed",
    target: { type: "user", id: targetUserId },
    before: { role: before.role }, after: { role: after.role },
    requestId: ctx.requestId, ip: ctx.ip,
  });
}
```

---

## Observability Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| **Log Noise** — DEBUG in prod at full volume | Default INFO in prod; enable DEBUG per-request via header |
| **Cardinality Explosion** — userId/orderId as labels | Low-cardinality labels only: method, route, status code |
| **Phantom Health** — `/health` always 200 | Split liveness (cheap) and readiness (deps with timeout) |
| **Alert Fatigue** — page on every error | Alert on rates and SLO windows, not individual events |
| **Orphaned Spans** — async tasks without context | Extract and forward context from triggering request |
| **PII in Logs** — email, SSN in log fields | Log IDs only; redact/hash sensitive values |
| **Mutable Audit Log** — deletable alongside app data | Append-only: immutable S3, dedicated audit DB, WORM |
| **Missing Baseline** — alerts before metrics exist | Instrument first, observe, set thresholds from real data |

---

## Cross-References

- `error-handling-patterns` — Error boundaries and correlation ID propagation at error sites
- `security-patterns-code-review` — Audit trail and PII overlap with security event logging
- `concurrency-patterns` — Correlation IDs must survive async boundaries
- `review-code-quality-process` — Observability review checklist and sign-off workflow
