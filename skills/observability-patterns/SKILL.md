---
name: observability-patterns
description: Use when reviewing code for observability correctness — covers Structured Logging, Log Levels, Distributed Tracing, Metrics (counters/gauges/histograms), Health Checks, Alerting, Correlation IDs, and Audit Trails with red flags and fix strategies across TypeScript, Python, Java, and Go
---

# Observability Patterns for Code Review

## Overview

Unobservable systems fail silently. Missing correlation IDs make incidents impossible to diagnose, cardinality explosions crash Prometheus, and health checks that always return 200 mask cascading failures. Use this guide during code review to catch observability hazards before they ship.

**When to use:** Reviewing services that call external systems, handle background jobs, or expose HTTP/gRPC APIs; evaluating logging, metrics, and tracing instrumentation; any code touching distributed async flows or admin operations.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Structured Logging | JSON logs with consistent context fields | `console.log()` with string concat, no correlation ID |
| Log Levels | DEBUG/INFO/WARN/ERROR applied by severity | Everything at INFO, ERROR for non-errors |
| Distributed Tracing | Trace ID propagated across service boundaries | Missing trace context in HTTP headers, no spans on external calls |
| Metrics | Counters, gauges, histograms on critical paths | No metrics on critical paths, cardinality explosion in labels |
| Health Checks | Liveness vs. Readiness probes serve different purposes | Health check always returns 200, dependency check in liveness |
| Alerting | Alert on symptoms (SLO breach), not causes (CPU%) | Alert on every error, no alert on latency SLO breach |
| Correlation IDs | Request ID threads through all async hops | Context lost at async boundary, no requestId in error responses |
| Audit Trails | Immutable record of who did what when | No audit log for admin operations, mutable audit records |

---

## Patterns in Detail

### 1. Structured Logging

**Intent:** Emit logs as machine-parseable JSON with consistent context fields (service, requestId, userId, duration) so log aggregators (Datadog, Splunk, Loki) can filter and correlate without regex.

**Code Review Red Flags:**
- `console.log("User " + userId + " failed")` — unstructured; cannot be queried by field
- PII (email, password, credit card) in log fields — compliance violation
- No `requestId` field — log lines cannot be correlated across services
- Log-and-throw: logging AND re-throwing causes duplicate entries upstream

**TypeScript — Before/After:**
```typescript
// BEFORE — unstructured; requestId missing; stack trace lost
console.log("Failed to process order for user " + userId + ": " + err.message);

// AFTER — structured; context-rich; no PII; single log site
logger.error("order.process.failed", {
  requestId: ctx.requestId,
  userId,                        // ID only, not email/name
  orderId: order.id,
  durationMs: Date.now() - startMs,
  error: { message: err.message, code: err.code },
});
```

**Go — zap (typed fields; zero allocation):**
```go
logger.Error("order.process.failed",
    zap.String("requestId", ctx.RequestID),
    zap.String("userId", userID),
    zap.Error(err),
    zap.Duration("duration", time.Since(start)))
```

---

### 2. Log Levels

**Intent:** Use DEBUG/INFO/WARN/ERROR at the correct severity so on-call engineers can set log level to WARN in production and see only actionable signals, not noise.

**Code Review Red Flags:**
- Everything logged at INFO — WARN/ERROR thresholds are meaningless for alerting
- `logger.error()` called for expected conditions (user not found on lookup) — too loud
- No WARN usage — the gap between INFO and ERROR is where degraded states live
- DEBUG logs containing secrets — debug is briefly enabled in prod for diagnosis

| Level | When to Use | Example |
|-------|-------------|---------|
| DEBUG | Detailed internals, development only | SQL query text, serialized payloads |
| INFO | Normal operations, business events | Order created, user logged in |
| WARN | Unexpected but recoverable | Retry #2 of 3, cache miss rate elevated |
| ERROR | Operation failed, human action needed | Payment declined, DB connection lost |

**Java — SLF4J Before/After:**
```java
// BEFORE — INFO for everything; ERROR for expected 404
log.info("Payment service unavailable, retrying...");
log.error("User not found: " + userId);

// AFTER — correct levels
log.warn("payment.service.retry", Map.of("attempt", attempt, "maxAttempts", 3));
log.info("user.not_found", Map.of("userId", userId));
log.error("payment.charge.failed", Map.of("userId", userId, "error", e.getMessage()));
```

---

### 3. Distributed Tracing

**Intent:** Propagate a trace context (traceId + spanId) across all service hops so a single distributed request can be reconstructed end-to-end in Jaeger, Zipkin, or AWS X-Ray.

**Code Review Red Flags:**
- Outgoing HTTP calls missing `traceparent` header — trace breaks at service boundary
- No child span before calling external services — latency attribution is lost
- `traceId` generated fresh in a downstream service instead of extracted from incoming request
- Async tasks (queues, cron jobs) started with no trace context — orphaned spans

**TypeScript — OpenTelemetry:**
```typescript
// BEFORE — outgoing call is a black box in traces
const result = await fetch("http://inventory-svc/check");

// AFTER — span wraps the call; context propagated in headers
const span = tracer.startSpan("inventory.check", {
  attributes: { "order.id": orderId },
});
const headers: Record<string, string> = {};
propagation.inject(context.with(trace.setSpan(context.active(), span), context.active()), headers);
try {
  return await fetch(inventoryUrl, { headers });
} catch (err) {
  span.recordException(err as Error);
  span.setStatus({ code: SpanStatusCode.ERROR });
  throw err;
} finally { span.end(); }
```

**Go — OpenTelemetry:**
```go
ctx, span := tracer.Start(ctx, "inventory.check",
    trace.WithAttributes(attribute.String("order.id", orderID)))
defer span.End()
req, _ := http.NewRequestWithContext(ctx, "GET", inventoryURL, nil)
otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
```

---

### 4. Metrics

**Intent:** Instrument counters (total requests), gauges (queue depth), and histograms (latency) on every critical path so dashboards and SLO alerts reflect real system health.

**Code Review Red Flags:**
- No metrics on HTTP handlers, queue consumers, or critical business operations
- High-cardinality labels: `labels: { userId, orderId }` — one time-series per entity; crashes Prometheus
- Gauge where a counter is correct — gauges reset to zero on restart
- Count only, no latency — a slow service looks healthy on counters alone

| Type | Measures | Example |
|------|----------|---------|
| Counter | Monotonically increasing total | `http_requests_total`, `errors_total` |
| Gauge | Point-in-time snapshot | `queue_depth`, `active_connections` |
| Histogram | Distribution + percentiles | `http_request_duration_seconds` |

**TypeScript — Prometheus client:**
```typescript
const requestDuration = new Histogram({
  name: "http_request_duration_seconds",
  labelNames: ["method", "route"],          // low cardinality — OK
  buckets: [0.005, 0.01, 0.05, 0.1, 0.5, 1],
});
// In handler:
const end = requestDuration.startTimer({ method: req.method, route: req.route.path });
try { return await handle(req); } finally { end(); }
```

**Python — prometheus_client:**
```python
LATENCY = Histogram("http_request_duration_seconds", "Latency", ["route"])
with LATENCY.labels(route="/orders").time():
    result = process_order(order)
```

---

### 5. Health Checks

**Intent:** Expose `/health/live` (is the process running?) and `/health/ready` (can it serve traffic?) as separate endpoints. Kubernetes uses liveness to restart crashed pods and readiness to stop routing traffic during degradation.

**Code Review Red Flags:**
- Single endpoint that always returns `200 OK` — Kubernetes never detects a broken pod
- Database check in the Liveness probe — a DB blip restarts all pods simultaneously
- No timeout on dependency probes — a hung DB check hangs the health endpoint itself
- Health endpoint requires authentication — Kubernetes cannot reach it

**TypeScript — Before/After:**
```typescript
// BEFORE — always 200; DB check in wrong probe
app.get("/health", async (_req, res) => { await db.query("SELECT 1"); res.json({ ok: true }); });

// AFTER — split probes with timeouts
app.get("/health/live", (_req, res) => res.json({ status: "alive" }));

app.get("/health/ready", async (_req, res) => {
  const checks = await Promise.allSettled([
    withTimeout(db.query("SELECT 1"), 2000),
    withTimeout(redis.ping(), 1000),
  ]);
  const failed = checks.filter(c => c.status === "rejected");
  res.status(failed.length ? 503 : 200).json({ status: failed.length ? "not_ready" : "ready" });
});
```

---

### 6. Alerting Patterns

**Intent:** Alert on user-visible symptoms (error rate > 1%, p99 > 500ms) rather than internal causes (CPU > 80%). Symptom-based alerts reduce false positives and map directly to user impact.

**Code Review Red Flags:**
- Alert on every individual error — alert fatigue leads to ignored channels
- No alert on SLO breach — users experience failures but no one is paged
- Alert threshold of zero — fires in staging, silenced in production
- Alert with no runbook link — on-call wastes 20 minutes finding the playbook

**Prometheus AlertManager — Before/After:**
```yaml
# WRONG — cause-based; fires when DB is slow even if users are unaffected
- alert: DatabaseSlowQueries
  expr: mysql_slow_queries_total > 10

# CORRECT — symptom-based SLO alert
- alert: OrderServiceHighErrorRate
  expr: |
    rate(http_requests_total{service="order-svc",status_code=~"5.."}[5m])
    / rate(http_requests_total{service="order-svc"}[5m]) > 0.01
  for: 2m
  labels: { severity: critical }
  annotations:
    summary: "Order service error rate > 1% for 2 minutes"
    runbook: "https://runbooks.internal/order-svc-errors"
```

---

### 7. Correlation IDs

**Intent:** Generate a unique `requestId` at every entry point and propagate it through all log statements, outgoing calls, queue messages, and error responses so a single user report can be traced end-to-end across services.

**Code Review Red Flags:**
- `requestId` not propagated into async callbacks or queue consumers — context lost mid-flow
- Error responses return no `requestId` — users cannot provide support a traceable reference
- `requestId` regenerated downstream instead of forwarded — correlation chain breaks
- ID not forwarded in outgoing HTTP headers (`X-Request-Id`, `X-Correlation-Id`)

**TypeScript — Express middleware with AsyncLocalStorage:**
```typescript
export const requestContext = new AsyncLocalStorage<{ requestId: string }>();

app.use((req, _res, next) => {
  const requestId = (req.headers["x-request-id"] as string) ?? uuidv4();
  requestContext.run({ requestId }, next);  // propagates through async boundaries automatically
});

// Any async handler — requestId always available without passing it manually
async function processOrder(orderId: string) {
  const { requestId } = requestContext.getStore()!;
  logger.info("order.process.start", { requestId, orderId });
  await fetch("http://inventory-svc/check", { headers: { "x-request-id": requestId } });
}

app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  const ctx = requestContext.getStore();
  res.status(500).json({ error: "Internal error", requestId: ctx?.requestId });
});
```

**Java — MDC (Mapped Diagnostic Context):**
```java
MDC.put("requestId", Optional.ofNullable(request.getHeader("X-Request-Id"))
    .orElse(UUID.randomUUID().toString()));
// logback.xml: %d [%X{requestId}] %-5level %logger - %msg%n
try { chain.doFilter(req, res); } finally { MDC.clear(); }
```

---

### 8. Audit Trails

**Intent:** Record an immutable log of every admin action and privilege change — capturing actor, action, before/after state, timestamp, and requestId — to support compliance, forensics, and rollback.

**Code Review Red Flags:**
- No audit logging for admin operations (delete user, change role, export data) — compliance violation
- Audit records stored alongside application data and subject to DELETE or UPDATE
- Before/after state not captured — impossible to reconstruct what changed
- Audit write inside the same DB transaction as the mutation — rolled back together

**TypeScript — append-only audit log:**
```typescript
async function changeUserRole(actor: Actor, targetUserId: string, newRole: Role, ctx: RequestContext) {
  const before = await userRepo.findById(targetUserId);
  await userRepo.updateRole(targetUserId, newRole);
  const after = await userRepo.findById(targetUserId);

  // Separate append-only store — never UPDATE or DELETE from this table
  await auditLog.append({
    id: uuidv4(), ts: new Date().toISOString(),
    actor: { id: actor.id, role: actor.role },
    action: "user.role.changed",
    target: { type: "user", id: targetUserId },
    before: { role: before.role }, after: { role: after.role },
    requestId: ctx.requestId, ip: ctx.ip,
  });
}
```

**Python — audit decorator:**
```python
def audit(action: str):
    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            result = fn(*args, **kwargs)
            audit_logger.info(action, extra={
                "actor_id": current_user.id, "target": kwargs.get("target_id"),
                "request_id": g.request_id, "ts": datetime.utcnow().isoformat(),
            })
            return result
        return wrapper
    return decorator

@audit("user.deleted")
def delete_user(target_id: str): ...
```

---

## Observability Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Log Noise** | DEBUG-level logs in production at full volume | Default INFO in prod; enable DEBUG per-request via header flag |
| **Cardinality Explosion** | Label values with userId, orderId — one series per entity | Use low-cardinality labels only: method, route template, status code |
| **Phantom Health** | `/health` always returns 200 regardless of dependency state | Split liveness (cheap) and readiness (dependency checks with timeout) |
| **Alert Fatigue** | Every error triggers a page; on-call silences the channel | Alert on rates and SLO windows, not individual events |
| **Orphaned Spans** | Async tasks started without propagating trace context | Extract and forward context from the triggering request or message |
| **PII in Logs** | Email, SSN, credit card in structured log fields | Log IDs only; redact or hash sensitive values before logging |
| **Mutable Audit Log** | Audit records deletable alongside application data | Use append-only storage: immutable S3 bucket, dedicated audit DB, WORM |
| **Missing Baseline** | No metrics before adding alerts; thresholds are guesses | Instrument first, observe in production, set thresholds from real data |

---

## Cross-References

- `error-handling-patterns` — Error Propagation and Error Boundaries: structured logging and correlation IDs are most valuable at error boundaries; ensure errors include `requestId` before surfacing to callers
- `security-patterns-code-review` — Audit Trails and PII handling: audit log requirements overlap with security event logging; sensitive fields must be redacted from observability data
- `concurrency-patterns` — Async/Await Pitfalls: correlation IDs must survive async boundaries; fire-and-forget tasks that drop context are the primary source of orphaned spans
- `review-code-quality-process` — Observability checklist: this skill provides the patterns; the process guide provides the review workflow and sign-off criteria
