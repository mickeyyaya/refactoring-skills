---
name: error-handling-patterns
description: Use when reviewing code for error handling correctness — covers Result/Either types, Exception hierarchies, Error propagation, Retry with backoff, Circuit breaker, Fail-fast, Graceful degradation, Error boundaries, Null Object/Optional, and Dead Letter Queue with red flags and fix strategies across TypeScript, Go, Rust, Python, and Java
---

# Error Handling Patterns for Code Review

## Overview

Swallowed exceptions hide production failures, missing retries cause cascading outages, and overly broad catches mask the real problem. Use this guide during code review to catch error handling hazards before they ship. Each pattern lists specific red flags to spot in a PR diff.

**When to use:** Reviewing code that calls external services, databases, file systems, or async operations; evaluating retry/circuit-breaker logic; any code touching user input or third-party data.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Result/Either | Return success or error as a value | Ignoring returned error values, missing `.ok` check |
| Exception Hierarchies | Structured, typed exception tree | Catching base `Exception`, throwing generic strings |
| Error Propagation | Each layer adds context before forwarding | Swallowing errors, leaking internal details to callers |
| Retry with Backoff | Retry transient failures with increasing delays | No backoff, no retry limit, retrying non-idempotent ops |
| Circuit Breaker | Stop calling a failing service after threshold | No timeout on HTTP calls, no circuit breaker on dependencies |
| Fail-Fast | Validate inputs immediately at boundaries | Deep processing before input validation, late null checks |
| Graceful Degradation | Partial results or fallback when dependency fails | Entire request fails because one optional service is down |
| Error Boundaries | Contain errors to prevent cascade | Unhandled promise rejections, no global error handler |
| Null Object / Optional | Typed absence eliminates null checks | Null returns from methods, unchecked Optional |
| Dead Letter Queue | Route unprocessable messages for later analysis | Silently dropping failed messages |

---

## Patterns in Detail

### 1. Result/Either Types

**Intent:** Return success or error as a typed value rather than throwing, forcing callers to handle both outcomes explicitly. Best for internal APIs and pipelines where errors are expected.

**Code Review Red Flags:**
- Returned error values ignored: `result, _ := doSomething()` in Go
- `Result` or `Either` returned but `.ok` / `.isOk()` never checked
- Mixing exceptions and Result types in the same layer — callers must know which to catch
- Unwrapping without checking: `.unwrap()` (Rust) panics on `Err`

**TypeScript — Before/After:**
```typescript
// BEFORE — throws on failure; caller must know to catch
function parseConfig(raw: string): Config { return JSON.parse(raw); }

// AFTER — error is part of the return type; caller is forced to handle it
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };
function parseConfig(raw: string): Result<Config, string> {
  try { return { ok: true, value: JSON.parse(raw) as Config }; }
  catch (e) { return { ok: false, error: `Invalid JSON: ${(e as Error).message}` }; }
}
const result = parseConfig(input);
if (!result.ok) { logger.error(result.error); process.exit(1); }
```

**Rust — `?` propagates `Err` automatically:**
```rust
fn start() -> Result<(), Box<dyn std::error::Error>> {
    let config = parse_config(raw_input)?;  // ? short-circuits on Err
    run_server(config)
}
```

**Go — idiomatic `(value, error)` return:**
```go
func parseConfig(raw string) (Config, error) {
    var cfg Config
    if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
        return Config{}, fmt.Errorf("parseConfig: %w", err)
    }
    return cfg, nil
}
```

---

### 2. Exception Hierarchies

**Intent:** Organize exceptions into a typed tree so callers catch at the right specificity — domain, infrastructure, or unexpected — without over-catching or under-catching.

**Code Review Red Flags:**
- Catching `Exception` / `Throwable` — also catches `OutOfMemoryError`, `StackOverflowError`
- `throw new Error("something went wrong")` — untyped, unclassifiable by callers
- Catch-and-rethrow without wrapping: loses original context and causes duplicate logs
- Empty catch block: `catch (IOException e) {}` — error silently discarded

**Java — Before/After:**
```java
// BEFORE — overly broad; log-and-throw causes duplicate logs upstream
try { return userRepository.findById(id); }
catch (Exception e) { log.error("error", e); throw e; }

// AFTER — typed hierarchy; retryable vs. permanent is explicit
class NotFoundException extends AppException { /* maps to 404 */ }
class ExternalServiceException extends AppException { /* retryable */ }

try {
    return userRepository.findById(id)
        .orElseThrow(() -> new NotFoundException("User not found: " + id));
} catch (DataAccessException e) {
    throw new ExternalServiceException("DB unavailable", e);  // wrap; don't re-log
}
```

**Python — After (typed hierarchy):**
```python
class AppError(Exception): pass
class NotFoundError(AppError): pass       # maps to 404
class ExternalServiceError(AppError): pass  # retryable

try:
    user = repo.find_user(user_id)
except NotFoundError: return Response(status=404)
except ExternalServiceError as e:
    logger.warning("unavailable: %s", e); raise  # let retry middleware handle
```

---

### 3. Error Propagation

**Intent:** Errors flow upward through layers, with each layer adding context — without swallowing the error or leaking internal details to API consumers.

**Code Review Red Flags:**
- `catch (e) { return null; }` — error swallowed, caller gets `null` with no explanation
- Stack trace lost by re-throwing a new exception without chaining the cause
- Raw SQL, file paths, or stack traces visible in API error responses
- Internal database errors surfaced directly to clients

**Go — context wrapping:**
```go
// BEFORE — caller sees "connection refused" with no context
func GetUser(id string) (User, error) { return db.QueryUser(id) }

// AFTER — each layer wraps with what it was doing
func GetUser(id string) (User, error) {
    user, err := db.QueryUser(id)
    if err != nil { return User{}, fmt.Errorf("GetUser(%s): %w", id, err) }
    return user, nil
}
// Error chain: "GetUser(abc123): QueryUser: dial tcp: connection refused"
// Caller can check: errors.Is(err, db.ErrNotFound)
```

**TypeScript — service wraps; controller translates to safe response:**
```typescript
async function getUser(id: string): Promise<User> {
  try { return await userRepo.findById(id); }
  catch (err) { throw new ServiceError(`getUser id=${id}`, { cause: err }); }
}
app.get('/users/:id', async (req, res) => {
  try { res.json(await getUser(req.params.id)); }
  catch (err) {
    logger.error('GET /users/:id', { err });            // full detail for ops
    res.status(500).json({ error: 'Internal error' });  // safe for clients
  }
});
```

---

### 4. Retry with Exponential Backoff

**Intent:** Retry transient failures with increasing delays between attempts to avoid amplifying load on a struggling service. Apply to external HTTP calls, DB connections, and message queue operations.

**Code Review Red Flags:**
- Immediate retry loop with no delay — hammers a struggling service, worsens the outage
- No maximum retry count — infinite retry loops that never give up
- Retrying non-idempotent operations (`POST /charge`) — may cause duplicate processing
- Catching all error types for retry — permanent errors (400, 404) should not be retried

**TypeScript — After:**
```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  { maxAttempts = 3, baseDelayMs = 200, retryable = (_e: unknown) => true } = {}
): Promise<T> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try { return await fn(); }
    catch (err) {
      if (attempt === maxAttempts || !retryable(err)) throw err;
      const delay = baseDelayMs * 2 ** (attempt - 1) + Math.random() * 100; // jitter
      await new Promise(r => setTimeout(r, delay));
    }
  }
  throw new Error('unreachable');
}
// Only retry 429/503, not 400/404
const user = await withRetry(() => fetchUser(id), {
  retryable: (e) => e instanceof HttpError && [429, 503].includes(e.status),
});
```

**Python — After (same pattern):**
```python
def with_retry(fn, max_attempts=3, base_delay=0.2, retryable=lambda e: True):
    for attempt in range(1, max_attempts + 1):
        try: return fn()
        except Exception as e:
            if attempt == max_attempts or not retryable(e): raise
            time.sleep(base_delay * 2 ** (attempt - 1) + random.uniform(0, 0.1))
```

Cross-reference: `concurrency-patterns` — Async/Await Pitfalls for fire-and-forget retry tasks that swallow errors.

---

### 5. Circuit Breaker

**Intent:** After a dependency fails repeatedly, stop calling it and return a fast failure until it recovers — preventing cascading failures. States: Closed → Open → Half-Open.

**Code Review Red Flags:**
- HTTP calls with no timeout — a slow dependency hangs threads indefinitely
- No circuit breaker on microservice calls — one slow service takes down callers
- No fallback when circuit is open — errors cascade to the client
- Circuit breaker threshold never tuned for actual traffic patterns

**TypeScript — minimal implementation:**
```typescript
class CircuitBreaker {
  private failures = 0; private nextAttempt = 0;
  private state: 'closed' | 'open' | 'half-open' = 'closed';
  constructor(private threshold = 5, private cooldownMs = 10_000) {}
  async call<T>(fn: () => Promise<T>): Promise<T> {
    if (this.state === 'open') {
      if (Date.now() < this.nextAttempt) throw new Error('Circuit open');
      this.state = 'half-open';
    }
    try {
      const r = await fn(); this.failures = 0; this.state = 'closed'; return r;
    } catch (err) {
      if (++this.failures >= this.threshold) {
        this.state = 'open'; this.nextAttempt = Date.now() + this.cooldownMs;
      }
      throw err;
    }
  }
}
```

**Java — Resilience4j (production-ready):**
```java
Try.ofSupplier(CircuitBreaker.decorateSupplier(CircuitBreaker.ofDefaults("svc"),
    () -> paymentClient.charge(req)))
   .recover(CallNotPermittedException.class, e -> fallbackPayment());
```

---

### 6. Fail-Fast

**Intent:** Validate inputs immediately at system boundaries — reject bad data before it propagates into business logic or storage.

**Code Review Red Flags:**
- Validation logic buried deep in a call chain — bad data reaches the database first
- `null` / `undefined` checks scattered through business logic instead of validated once at entry
- No input validation on public API endpoints — trusting caller-provided data

**TypeScript — Before/After (schema validation at boundary):**
```typescript
// BEFORE — undefined userId propagates through 3 calls before crashing
async function processOrder(order: Order) {
  return chargeCard((await getUser(order.userId)).card, calculateTotal(order.items));
}

// AFTER — Zod schema rejects bad input immediately with field-level detail
const OrderSchema = z.object({
  userId: z.string().uuid(),
  items: z.array(z.object({ sku: z.string(), qty: z.number().int().positive() })).min(1),
});
async function processOrder(raw: unknown) {
  const order = OrderSchema.parse(raw);  // throws ZodError at the entry point
  return chargeCard((await getUser(order.userId)).card, calculateTotal(order.items));
}
```

**Go — guard clauses:**
```go
func ProcessOrder(order Order) error {
    if order.UserID == "" { return errors.New("userID required") }
    if len(order.Items) == 0 { return errors.New("items required") }
    return processValidOrder(order)
}
```

---

### 7. Graceful Degradation

**Intent:** When a non-critical dependency fails, return a partial result or fallback rather than failing the entire request. Apply to optional enrichment features (recommendations, personalization).

**Code Review Red Flags:**
- Optional service failure causes a 500 on the core endpoint
- No timeout on optional service calls — slow dependency stalls the entire response
- Fallback returns misleading data (stale cache not labeled as such)
- No monitoring when degraded mode is active — silent degradation masks outages

**TypeScript — Before/After:**
```typescript
// BEFORE — optional service failure fails the entire endpoint
async function getProduct(id: string): Promise<ProductPage> {
  const [product, recs] = await Promise.all([
    productRepo.findById(id),
    recommendationService.getFor(id),  // optional — should not be fatal
  ]);
  return { product, recommendations: recs };
}

// AFTER — required service can throw; optional degrades to fallback
async function getProduct(id: string): Promise<ProductPage> {
  const product = await productRepo.findById(id);
  const recommendations = await recommendationService.getFor(id)
    .catch(err => { logger.warn('Recs degraded', { id, err }); return []; });
  return { product, recommendations };
}
```

---

### 8. Error Boundaries

**Intent:** Contain errors at defined boundaries so that a failure in one subsystem does not cascade into an unrecoverable crash of the entire application.

**Code Review Red Flags:**
- No global `unhandledRejection` / `uncaughtException` handler — Node.js process crashes silently
- React component tree with no `ErrorBoundary` — one render error unmounts the entire UI
- Message consumer crashes on a bad message without acknowledging or dead-lettering it

**TypeScript (Node.js) — After:**
```typescript
process.on('unhandledRejection', (r) => { logger.error('Unhandled rejection', r); process.exit(1); });
process.on('uncaughtException', (e) => { logger.error('Uncaught exception', e); process.exit(1); });
// Express middleware — last-resort error boundary
app.use((err: Error, req: Request, res: Response, _next: NextFunction) => {
  logger.error('Request error', { err, path: req.path });
  res.status(500).json({ error: 'Internal server error' });
});
```

**Java — Spring @ControllerAdvice:**
```java
@ControllerAdvice
public class GlobalExceptionHandler {
    @ExceptionHandler(NotFoundException.class)
    ResponseEntity<ErrorResponse> notFound(NotFoundException ex) {
        return ResponseEntity.status(404).body(new ErrorResponse(ex.getMessage()));
    }
    @ExceptionHandler(Exception.class)
    ResponseEntity<ErrorResponse> unexpected(Exception ex) {
        log.error("Unexpected", ex);
        return ResponseEntity.status(500).body(new ErrorResponse("Internal error"));
    }
}
```

Cross-reference: `concurrency-patterns` — Async/Await Pitfalls for fire-and-forget tasks that bypass error boundaries.

---

### 9. Null Object / Optional

**Intent:** Eliminate null-check clutter and NPE crashes by representing absence with a typed container or safe default object.

**Code Review Red Flags:**
- Method returns `null` instead of `Optional` — callers forget to null-check
- `Optional.get()` called without `isPresent()` — same risk as direct null dereference
- `?.` chains so long that the failure point is invisible

**Java — Before/After:**
```java
// BEFORE — null return; caller forgets check, NPE in production
public User findUser(String id) { return userMap.get(id); }

// AFTER — Optional forces caller to handle absence
public Optional<User> findUser(String id) { return Optional.ofNullable(userMap.get(id)); }
// Caller: safe pipeline, no NPE
findUser(id).map(User::getName).orElse("Anonymous");
```

**Rust — Option<T> requires exhaustive match:**
```rust
match find_user(id) {
    Some(user) => process(user),
    None => return Err(AppError::NotFound(id.to_string())),
}
```

---

### 10. Dead Letter Queue

**Intent:** When a message cannot be processed after retries, route it to a separate queue for inspection and replay rather than dropping it silently. Applies to Kafka, SQS, RabbitMQ, and background job processors.

**Code Review Red Flags:**
- Failed messages acknowledged and discarded — data loss with no audit trail
- No retry limit — bad message retried indefinitely, blocking the queue
- DLQ exists but is never monitored or drained — unprocessable messages accumulate silently

**TypeScript — After (SQS):**
```typescript
async function processMessage(msg: SQSMessage): Promise<void> {
  const attempts = Number(msg.Attributes?.ApproximateReceiveCount ?? 1);
  try {
    await handleEvent(JSON.parse(msg.Body));
    await sqs.deleteMessage({ QueueUrl, ReceiptHandle: msg.ReceiptHandle });
  } catch (err) {
    logger.error('Processing failed', { err, attempts });
    if (attempts >= 3) metrics.increment('sqs.dlq.routed');
    // Do NOT delete — SQS will retry and auto-route to DLQ after maxReceiveCount
  }
}
```

Cross-reference: `concurrency-patterns` — Producer-Consumer for bounded queue patterns and backpressure.

---

## Error Handling Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Pokemon Exception Handling** | `catch(e) {}` — catches everything, handles nothing | Handle specific errors; re-throw or log what you cannot handle |
| **Error Swallowing** | `catch(e) { log(e); }` without re-throwing | Decide: recover, rethrow, or convert to Result — never silently absorb |
| **String-Typed Errors** | `throw "something went wrong"` — no type, no stack trace | Always throw typed `Error` objects or domain-specific subclasses |
| **Control Flow via Exceptions** | Using try/catch for expected conditions (parse, lookup) | Use Result types or explicit checks for expected failure paths |
| **Log and Throw** | Log error then re-throw — causes duplicate log entries | Log ONCE at the boundary; lower layers wrap and rethrow without logging |
| **Overly Broad Catch** | Catching `Exception` when only `IOException` is expected | Catch the most specific type that covers the failure mode |
| **Silent Null Return** | Returning `null` from a method that "failed" | Return `Optional`, `Result`, or throw a typed exception |
| **Retry Without Idempotency** | Retrying `POST /charge` — customer charged twice | Verify idempotency before adding retry; use idempotency keys |

**Pokemon Exception Handling — TypeScript fix:**
```typescript
// WRONG: try { return await fetchUser(id); } catch (e) {}  // swallows all errors
// CORRECT — handle expected, propagate the rest
async function loadUser(id: string): Promise<User | null> {
  try { return await fetchUser(id); }
  catch (err) {
    if (err instanceof NotFoundError) return null;  // expected — safe to swallow
    throw err;                                       // unexpected — propagate up
  }
}
```

---

## Cross-References

- `concurrency-patterns` — Async/Await Pitfalls: unobserved promise rejections and fire-and-forget tasks are a critical intersection of async and error handling
- `refactor-functional-patterns` — Monadic error handling: `map`, `flatMap`, `chain` over Result/Option types for pipeline-style error propagation
- `review-code-quality-process` — Error handling checklist: this skill provides the patterns; the process guide provides the review workflow
- `detect-code-smells` — "Shotgun Surgery" on error handling: scattered try/catch blocks all doing the same thing indicate a missing centralized error boundary
