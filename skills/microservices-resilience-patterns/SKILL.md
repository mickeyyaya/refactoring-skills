---
name: microservices-resilience-patterns
description: Use when designing or reviewing microservice architectures — covers Saga (choreography vs orchestration), Bulkhead, API Gateway, Circuit Breaker, Retry with Backoff, Fallback and graceful degradation, Health Probes, Service Mesh/Sidecar, and resilience anti-patterns (retry storm, cascading failure, thundering herd) with multi-language examples in TypeScript, Java, and Go
---

# Microservices Resilience Patterns

## Overview

Distributed systems fail in partial and unpredictable ways. A single slow dependency can exhaust thread pools, a retry storm can amplify a brief outage, and a missing compensating transaction can leave data permanently inconsistent.

**When to use:** Designing new services, reviewing inter-service communication, adding failure recovery logic, evaluating observability coverage, or analyzing post-incident root causes.

## Quick Reference

| Pattern | Core Idea | Primary Risk Without It |
|---------|-----------|------------------------|
| Saga | Multi-step distributed transaction with compensating rollback | Inconsistent state when a step fails mid-flow |
| Bulkhead | Isolate thread pools / connection pools by dependency | One slow service exhausts resources for all services |
| API Gateway | Single entry point for routing, auth, rate limiting | Auth drift across services; per-service exposure |
| Circuit Breaker | Stop calling a failing service after threshold breached | Cascading failure as callers pile up waiting on a dead dependency |
| Retry with Backoff | Re-attempt transient failures with increasing delay and jitter | Retry storm amplifying a brief outage; double-charging on non-idempotent ops |
| Fallback / Degradation | Return partial or cached result when dependency is unavailable | Total outage caused by one optional downstream service |
| Health Probes | Liveness, readiness, and startup endpoints for orchestrators | Traffic routed to unhealthy pods; stuck containers never restarted |
| Service Mesh / Sidecar | Offload TLS, retries, and observability to a proxy sidecar | Duplicated per-service retry/auth logic; inconsistent telemetry |

---

## Patterns in Detail

### 1. Saga Pattern

Coordinates multi-step distributed transactions without two-phase commit. Each step publishes an event or calls the next service; on failure, compensating transactions roll back completed steps in reverse order.

**Two styles:**
- **Choreography** — each service listens for events and acts autonomously. Decoupled, but hard to trace.
- **Orchestration** — central orchestrator calls each step in sequence and issues compensating calls on failure. Easier to observe but a coordination bottleneck.

**Red Flags:**
- No compensating transaction defined — partial failures leave orphaned records
- Compensating transactions are not idempotent — double invocation creates double rollback
- Saga state stored only in memory — orchestrator crash loses saga progress
- No timeout on a saga step — blocked saga holds locks indefinitely

**TypeScript — Orchestration-style Saga:**
```typescript
interface SagaStep<T> {
  execute: (ctx: T) => Promise<T>;
  compensate: (ctx: T) => Promise<void>;
}

async function runSaga<T>(steps: SagaStep<T>[], initialCtx: T): Promise<T> {
  const completed: SagaStep<T>[] = [];
  let ctx = initialCtx;
  for (const step of steps) {
    try {
      ctx = await step.execute(ctx);
      completed.push(step);
    } catch (err) {
      for (const done of [...completed].reverse()) {
        await done.compensate(ctx).catch(e => logger.error('Compensate failed', { e }));
      }
      throw new SagaFailedError('Saga rolled back', { cause: err });
    }
  }
  return ctx;
}

const orderSaga: SagaStep<OrderContext>[] = [
  {
    execute: async (ctx) => ({ ...ctx, reservationId: await inventoryService.reserve(ctx.items) }),
    compensate: async (ctx) => inventoryService.release(ctx.reservationId),
  },
  {
    execute: async (ctx) => ({ ...ctx, paymentId: await paymentService.charge(ctx.userId, ctx.total) }),
    compensate: async (ctx) => paymentService.refund(ctx.paymentId),
  },
];
```

**Java — Choreography via domain events (annotation-driven; different idiom from TS orchestration):**
```java
@EventHandler
public void on(OrderPlacedEvent event) {
    try {
        inventoryRepository.reserve(event.orderId(), event.items());
        eventBus.publish(new InventoryReservedEvent(event.orderId()));
    } catch (InsufficientStockException e) {
        eventBus.publish(new InventoryReservationFailedEvent(event.orderId(), e.getMessage()));
    }
}
```

**Go — idempotent compensating transaction:**
```go
func (s *PaymentService) Refund(ctx context.Context, paymentID string) error {
    existing, err := s.store.FindRefund(ctx, paymentID)
    if err == nil && existing != nil {
        return nil // already refunded — idempotent
    }
    _, err = s.processor.IssueRefund(ctx, paymentID)
    return fmt.Errorf("Refund(%s): %w", paymentID, err)
}
```

---

### 2. Bulkhead Pattern

Prevents thread-pool or connection-pool exhaustion from cascading. Assign each downstream dependency its own bounded pool.

**Two implementations:**
- **Thread pool isolation** — separate executor per downstream call (Hystrix/Resilience4j style)
- **Connection pool partitioning** — cap DB/HTTP connections per service or tenant

**Red Flags:**
- Single shared HTTP client for all downstream services — one slow endpoint blocks all calls
- Unlimited connection pool size — a dependency surge consumes all DB connections
- Bulkhead too large (defeats isolation) or too small (overly restrictive under normal load)
- No metrics on bulkhead saturation — you don't know it is full until requests fail

**TypeScript — semaphore-based bulkhead:**
```typescript
class Bulkhead {
  private active = 0;
  constructor(private readonly maxConcurrent: number) {}

  async execute<T>(fn: () => Promise<T>): Promise<T> {
    if (this.active >= this.maxConcurrent) {
      throw new BulkheadRejectedError(`Bulkhead full (${this.active}/${this.maxConcurrent})`);
    }
    this.active++;
    try { return await fn(); } finally { this.active--; }
  }
}

const inventoryBulkhead = new Bulkhead(20);
const paymentBulkhead = new Bulkhead(10);
```

**Java — Resilience4j Bulkhead (annotation/builder API; different from TS semaphore):**
```java
BulkheadConfig config = BulkheadConfig.custom()
    .maxConcurrentCalls(25)
    .maxWaitDuration(Duration.ofMillis(100))
    .build();
Bulkhead inventoryBulkhead = Bulkhead.of("inventory", config);
Try.ofSupplier(Bulkhead.decorateSupplier(inventoryBulkhead, () -> inventoryClient.check(orderId)))
   .recover(BulkheadFullException.class, e -> InventoryStatus.UNKNOWN);
```

**Go — channel-based resource pool (Go-idiomatic; different from semaphore):**
```go
type Pool struct{ tokens chan struct{} }

func NewPool(size int) *Pool {
    ch := make(chan struct{}, size)
    for i := 0; i < size; i++ { ch <- struct{}{} }
    return &Pool{ch}
}

func (p *Pool) Acquire(ctx context.Context) error {
    select {
    case <-p.tokens: return nil
    case <-ctx.Done(): return fmt.Errorf("bulkhead: %w", ctx.Err())
    }
}
func (p *Pool) Release() { p.tokens <- struct{}{} }
```

---

### 3. API Gateway Pattern

Single entry point for all external traffic: routing, TLS termination, rate limiting, auth offloading, and request aggregation.

**Red Flags:**
- Auth logic duplicated in every microservice — drift leads to security gaps
- No rate limiting at the gateway — misbehaving clients exhaust backend resources
- Gateway does business logic — becomes a bottleneck and deployment risk
- No tracing headers injected — distributed traces are incomplete

**TypeScript — lightweight gateway middleware:**
```typescript
import express from 'express';
import { createProxyMiddleware } from 'http-proxy-middleware';
const app = express();
app.use(async (req, res, next) => {
  const token = req.headers.authorization?.replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'Unauthorized' });
  try {
    const payload = await verifyJwt(token);
    req.headers['x-user-id'] = payload.sub;
    req.headers['x-trace-id'] ??= crypto.randomUUID();
    next();
  } catch { res.status(401).json({ error: 'Invalid token' }); }
});

app.use(rateLimit({ windowMs: 60_000, max: 100, keyGenerator: (r) => r.headers['x-user-id'] as string }));
app.use('/orders', createProxyMiddleware({ target: 'http://order-service:3001', changeOrigin: true }));
app.use('/inventory', createProxyMiddleware({ target: 'http://inventory-service:3002', changeOrigin: true }));
```

**Java — Spring Cloud Gateway (declarative route DSL; different from TS middleware):**
```java
@Bean
public RouteLocator routes(RouteLocatorBuilder builder) {
    return builder.routes()
        .route("order-service", r -> r.path("/orders/**")
            .filters(f -> f
                .addRequestHeader("X-Gateway", "true")
                .requestRateLimiter(c -> c.setRateLimiter(redisRateLimiter()))
                .circuitBreaker(c -> c.setName("orderCB").setFallbackUri("forward:/fallback")))
            .uri("lb://order-service"))
        .build();
}
```

---

### 4. Circuit Breaker

Tracks failure rates against a rolling window. After crossing a threshold it opens, rejecting calls immediately. After cooldown it enters half-open, sending one probe. Success closes; failure re-opens.

**States:** Closed (count failures) → Open (reject all, use fallback) → Half-open (one probe)

**Red Flags:**
- No timeout on HTTP calls — circuit never trips because calls hang instead of failing
- Threshold never tuned — fires on transient spikes or never fires on real outages
- No fallback when open — callers receive raw `CircuitOpenError`
- One global circuit breaker — noisy service trips the breaker for unrelated services

**TypeScript:**
```typescript
type CBState = 'closed' | 'open' | 'half-open';

class CircuitBreaker {
  private failures = 0;
  private state: CBState = 'closed';
  private nextAttempt = 0;

  constructor(private readonly threshold = 5, private readonly cooldownMs = 15_000) {}

  async call<T>(fn: () => Promise<T>, fallback?: () => T): Promise<T> {
    if (this.state === 'open') {
      if (Date.now() < this.nextAttempt) {
        if (fallback) return fallback();
        throw new Error('Circuit open');
      }
      this.state = 'half-open';
    }
    try {
      const result = await fn();
      this.failures = 0; this.state = 'closed';
      return result;
    } catch (err) {
      if (++this.failures >= this.threshold) {
        this.state = 'open';
        this.nextAttempt = Date.now() + this.cooldownMs;
      }
      if (fallback) return fallback();
      throw err;
    }
  }
}
```

**Java — Resilience4j (sliding window + fallback; different config API from TS):**
```java
CircuitBreakerConfig config = CircuitBreakerConfig.custom()
    .slidingWindowSize(10)
    .failureRateThreshold(50)
    .waitDurationInOpenState(Duration.ofSeconds(15))
    .permittedNumberOfCallsInHalfOpenState(2)
    .build();
CircuitBreaker cb = CircuitBreaker.of("payment", config);
String result = cb.executeWithFallback(() -> paymentClient.charge(request), t -> "FALLBACK");
```

**Go — gobreaker library:**
```go
cb := gobreaker.NewCircuitBreaker(gobreaker.Settings{
    Name: "inventory", MaxRequests: 1,
    Interval: 10 * time.Second, Timeout: 15 * time.Second,
    ReadyToTrip: func(counts gobreaker.Counts) bool {
        return counts.ConsecutiveFailures > 5
    },
})
result, err := cb.Execute(func() (interface{}, error) {
    return inventoryClient.Check(ctx, itemID)
})
```

---

### 5. Retry with Backoff at Service Level

Only retry idempotent operations or those protected by an idempotency key. Use exponential backoff with jitter to prevent thundering herd. Never retry permanent errors.

**Red Flags:**
- Retry on `POST /charge` without an idempotency key — double charge risk
- No jitter — synchronized retries amplify load spikes
- No retry budget — unbounded retries under sustained failure; retry storm
- Retrying 400/404 — permanent errors waste resources and delay the caller

**TypeScript:**
```typescript
async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  opts: { maxAttempts?: number; baseMs?: number; isRetryable?: (e: unknown) => boolean } = {}
): Promise<T> {
  const { maxAttempts = 3, baseMs = 200, isRetryable = () => true } = opts;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try { return await fn(); } catch (err) {
      if (attempt === maxAttempts || !isRetryable(err)) throw err;
      const delay = Math.random() * baseMs * 2 ** attempt; // full jitter
      await new Promise(r => setTimeout(r, delay));
    }
  }
  throw new Error('unreachable');
}

const idempotencyKey = crypto.randomUUID();
await retryWithBackoff(
  () => paymentService.charge({ ...req, idempotencyKey }),
  { isRetryable: (e) => e instanceof HttpError && [429, 503].includes(e.status) }
);
```

Cross-reference: `error-handling-patterns` — Retry with Exponential Backoff for single-service retry mechanics.

---

### 6. Fallback and Graceful Degradation

Return a meaningful partial result rather than failing entirely. Distinguish required dependencies (fail the request) from optional dependencies (degrade gracefully). Log every degradation event.

**Red Flags:**
- Optional service failure causes a 500 on the parent endpoint
- Stale cache returned without any indication it is stale
- Fallback silently swallows the error — degraded mode is invisible
- No circuit breaker paired with the fallback — degraded path attempted on every request

**TypeScript:**
```typescript
async function getProductPage(id: string): Promise<ProductPage> {
  const product = await productRepo.findById(id); // required — fail if unavailable

  const [recommendations, reviews, inventory] = await Promise.allSettled([
    recommendationService.getFor(id),
    reviewService.getSummary(id),
    inventoryService.getStatus(id),
  ]);

  return {
    product,
    recommendations: recommendations.status === 'fulfilled'
      ? recommendations.value : (logger.warn('Recs degraded', { id }), []),
    reviews: reviews.status === 'fulfilled'
      ? reviews.value : (logger.warn('Reviews degraded', { id }), null),
    inStock: inventory.status === 'fulfilled'
      ? inventory.value.inStock : (logger.warn('Inventory degraded', { id }), true),
    _degraded: [recommendations, reviews, inventory]
      .filter(r => r.status === 'rejected')
      .map((_, i) => ['recommendations', 'reviews', 'inventory'][i]),
  };
}
```

---

### 7. Health Probes

Three probe types manage container lifecycle in Kubernetes. Misconfiguration causes premature traffic or stuck pods.

| Probe | Question | Failure action |
|-------|----------|----------------|
| Liveness | Is the container alive? | Restart container |
| Readiness | Is it ready to serve traffic? | Remove from load balancer |
| Startup | Has init completed? | Block liveness/readiness until passes |

**Red Flags:**
- Liveness probe calls downstream services — downstream failure triggers unnecessary restart
- No readiness probe — traffic sent to a pod still running migrations
- Health endpoint performs expensive queries — probes add load on every interval
- Startup probe timeout too short — slow JVM init causes restart loop

**TypeScript — Express health endpoints:**
```typescript
app.get('/healthz/live', (_req, res) =>
  res.json({ status: 'alive', uptime: process.uptime() })
);

app.get('/healthz/ready', async (_req, res) => {
  const checks = await Promise.allSettled([db.ping(), cache.ping()]);
  const failures = checks
    .map((c, i) => ({ name: ['db', 'cache'][i], ok: c.status === 'fulfilled' }))
    .filter(c => !c.ok);
  failures.length > 0
    ? res.status(503).json({ status: 'not ready', failures })
    : res.json({ status: 'ready' });
});

let started = false;
app.get('/healthz/startup', (_req, res) =>
  res.status(started ? 200 : 503).json({ started })
);
```

**Kubernetes probe config (essential fields only):**
```yaml
livenessProbe:
  httpGet: { path: /healthz/live, port: 3000 }
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3
readinessProbe:
  httpGet: { path: /healthz/ready, port: 3000 }
  periodSeconds: 5
  failureThreshold: 2
startupProbe:
  httpGet: { path: /healthz/startup, port: 3000 }
  failureThreshold: 30
  periodSeconds: 5   # allows up to 150s for startup
```

---

### 8. Service Mesh / Sidecar Pattern

A proxy sidecar (Envoy/Istio, Linkerd) intercepts all traffic and handles mTLS, retries, circuit breaking, load balancing, and telemetry — without application code changes.

**Benefits:**
- Consistent retry/circuit breaker policy without per-service implementation
- Automatic distributed tracing headers injected across all services
- mTLS between every service pair with zero application-layer code
- Traffic splitting enables canary and blue/green deployments

**Red Flags:**
- Retry policy in sidecar AND application code — double retry on failure
- No timeout in VirtualService — requests hang indefinitely even with a mesh
- Sidecar disabled for a service — no telemetry; weakest link in the mesh
- No peer authentication policy — internal traffic unencrypted

**Istio VirtualService with retry and timeout:**
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-service
spec:
  hosts: [payment-service]
  http:
    - retries:
        attempts: 3
        perTryTimeout: 2s
        retryOn: 5xx,reset,connect-failure,retriable-4xx
      timeout: 8s
      route:
        - destination:
            host: payment-service
            subset: v1
```

**PeerAuthentication — enforce mTLS cluster-wide:**
```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT
```

Cross-reference: `error-handling-patterns` — Circuit Breaker for application-layer circuit breaking when a service mesh is not available.

---

### 9. Resilience Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Retry Storm** | Many callers retry a recovering service, preventing recovery | Add jitter to backoff; circuit breaker sheds load when open |
| **Cascading Failure** | Slow dependency A exhausts caller B's pool, causing B to fail | Bulkhead per dependency; timeout on all outbound calls; circuit breaker |
| **Thundering Herd** | Cache expiry or restart causes every caller to hit backend at once | Probabilistic early expiry; lock-based refresh; request coalescing |
| **Chatty Retries** | Retrying permanent errors (400, 404) or non-idempotent ops | Classify errors as retryable vs. permanent before retrying |
| **Liveness Probe Dependency** | Liveness probe calls downstream — external failure causes mass restarts | Liveness checks only in-process state |
| **Missing Idempotency** | Retrying state-changing calls without an idempotency key — duplicates | Use idempotency keys; verify at receiver before processing |
| **Synchronous Saga** | Long saga in a request thread — timeout kills a partial saga | Run sagas asynchronously; persist saga state to durable store |
| **No Bulkhead** | Shared pool across all services — one slow service blocks everything | Assign a separate bounded pool to each dependency |

**Retry storm — WRONG vs CORRECT:**
```typescript
// WRONG: fixed delay — all retrying callers hit backend simultaneously
await new Promise(r => setTimeout(r, 500));

// CORRECT: full jitter prevents synchronized retry waves
const jitter = Math.random() * baseMs * 2 ** attempt;
await new Promise(r => setTimeout(r, jitter));
```

**Cascading failure prevention — Go (context timeout pattern):**
```go
ctx, cancel := context.WithTimeout(parentCtx, 2*time.Second)
defer cancel()
resp, err := inventoryClient.Check(ctx, itemID)
if err != nil {
    return fallbackInventoryStatus(), nil
}
```

**Cache stampede fix — TypeScript (XFetch probabilistic early refresh):**
```typescript
function shouldRefreshEarly(expiryMs: number, betaFactor = 1): boolean {
  return Date.now() - betaFactor * Math.log(Math.random()) * 1000 >= expiryMs;
}
```

---

## Compensating Transactions, Rollback, and Idempotency

Every saga step that modifies external state MUST have a defined compensating transaction — forward-moving operations that logically reverse the effect (not database undo). Both steps and compensating transactions must be idempotent.

| Step | Compensating Transaction |
|------|--------------------------|
| Reserve inventory | Release reservation |
| Charge payment | Issue refund |
| Send confirmation email | Send cancellation email |
| Create shipment | Cancel shipment |

**TypeScript — idempotency key pattern:**
```typescript
async function processPayment(req: PaymentRequest): Promise<PaymentResult> {
  const existing = await paymentStore.findByIdempotencyKey(req.idempotencyKey);
  if (existing) return existing; // already processed
  const result = await paymentProcessor.charge(req);
  await paymentStore.saveWithKey(req.idempotencyKey, result);
  return result;
}
```

### Rollback Checklist

- [ ] Compensating transaction defined for every step that mutates state
- [ ] Each compensating transaction is idempotent
- [ ] Saga state persisted durably (database, not in-memory) before each step
- [ ] Compensation failures are logged and alarmed — require manual intervention
- [ ] Timeout defined for each saga step — no step blocks indefinitely

---

## Cross-References

- `error-handling-patterns` — Circuit Breaker and Retry with Backoff for single-service implementations
- `concurrency-patterns` — Producer-Consumer and Async/Await Pitfalls for queue-based saga choreography
- `detect-code-smells` — Shotgun Surgery: compensating transaction logic scattered across services indicates a missing saga orchestrator
- `review-code-quality-process` — Resilience checklist: use patterns here alongside the review workflow
