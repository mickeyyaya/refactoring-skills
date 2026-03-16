---
name: error-handling-patterns
description: Use when reviewing code for error handling correctness — covers Result/Either types, Exception hierarchies, Error propagation, Retry with backoff, Circuit breaker, Fail-fast, Graceful degradation, Error boundaries, Null Object/Optional, and Dead Letter Queue with red flags and fix strategies across TypeScript, Go, Rust, Python, and Java
---

# Error Handling Patterns for Code Review

## Overview

Swallowed exceptions hide production failures, missing retries cause cascading outages, and overly broad catches mask the real problem. Use this guide during code review to catch error handling hazards before they ship.

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

**Red Flags:**
- Returned error values ignored: `result, _ := doSomething()` in Go
- `Result` or `Either` returned but `.ok` / `.isOk()` never checked
- Mixing exceptions and Result types in the same layer
- Unwrapping without checking: `.unwrap()` (Rust) panics on `Err`

**TypeScript:**
```typescript
// BEFORE — throws on failure; caller must know to catch
function parseConfig(raw: string): Config { return JSON.parse(raw); }

// AFTER — error is part of the return type
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
    let config = parse_config(raw_input)?;
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

**Red Flags:**
- Catching `Exception` / `Throwable` — also catches `OutOfMemoryError`
- `throw new Error("something went wrong")` — untyped, unclassifiable
- Catch-and-rethrow without wrapping: loses context, causes duplicate logs
- Empty catch block: `catch (IOException e) {}`

**Java:**
```java
// BEFORE — overly broad; log-and-throw causes duplicate logs
try { return userRepository.findById(id); }
catch (Exception e) { log.error("error", e); throw e; }

// AFTER — typed hierarchy; retryable vs. permanent is explicit
class NotFoundException extends AppException { /* maps to 404 */ }
class ExternalServiceException extends AppException { /* retryable */ }

try {
    return userRepository.findById(id)
        .orElseThrow(() -> new NotFoundException("User not found: " + id));
} catch (DataAccessException e) {
    throw new ExternalServiceException("DB unavailable", e);
}
```

**Python:**
```python
class AppError(Exception): pass
class NotFoundError(AppError): pass
class ExternalServiceError(AppError): pass

try:
    user = repo.find_user(user_id)
except NotFoundError: return Response(status=404)
except ExternalServiceError as e:
    logger.warning("unavailable: %s", e); raise
```

---

### 3. Error Propagation

**Red Flags:**
- `catch (e) { return null; }` — error swallowed, caller gets `null` with no explanation
- Stack trace lost by re-throwing without chaining the cause
- Raw SQL, file paths, or stack traces visible in API error responses

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

**Red Flags:**
- Immediate retry loop with no delay — hammers a struggling service
- No maximum retry count — infinite loops
- Retrying non-idempotent operations (`POST /charge`) — duplicate processing
- Catching all error types for retry — permanent errors (400, 404) should not be retried

**TypeScript:**
```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  { maxAttempts = 3, baseDelayMs = 200, retryable = (_e: unknown) => true } = {}
): Promise<T> {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try { return await fn(); }
    catch (err) {
      if (attempt === maxAttempts || !retryable(err)) throw err;
      const delay = baseDelayMs * 2 ** (attempt - 1) + Math.random() * 100;
      await new Promise(r => setTimeout(r, delay));
    }
  }
  throw new Error('unreachable');
}
const user = await withRetry(() => fetchUser(id), {
  retryable: (e) => e instanceof HttpError && [429, 503].includes(e.status),
});
```

**Python:**
```python
def with_retry(fn, max_attempts=3, base_delay=0.2, retryable=lambda e: True):
    for attempt in range(1, max_attempts + 1):
        try: return fn()
        except Exception as e:
            if attempt == max_attempts or not retryable(e): raise
            time.sleep(base_delay * 2 ** (attempt - 1) + random.uniform(0, 0.1))
```

Cross-reference: `concurrency-patterns` — Async/Await Pitfalls for fire-and-forget retry tasks.

---

### 5. Circuit Breaker

**Red Flags:**
- HTTP calls with no timeout — slow dependency hangs threads indefinitely
- No circuit breaker on microservice calls — one slow service takes down callers
- No fallback when circuit is open
- Threshold never tuned for actual traffic patterns

**TypeScript:**
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

**Java — Resilience4j:**
```java
Try.ofSupplier(CircuitBreaker.decorateSupplier(CircuitBreaker.ofDefaults("svc"),
    () -> paymentClient.charge(req)))
   .recover(CallNotPermittedException.class, e -> fallbackPayment());
```

---

### 6. Fail-Fast

**Red Flags:**
- Validation buried deep in call chain — bad data reaches the database first
- `null`/`undefined` checks scattered through business logic instead of validated at entry
- No input validation on public API endpoints

**TypeScript:**
```typescript
// BEFORE — undefined userId propagates through 3 calls before crashing
async function processOrder(order: Order) {
  return chargeCard((await getUser(order.userId)).card, calculateTotal(order.items));
}

// AFTER — Zod schema rejects bad input immediately
const OrderSchema = z.object({
  userId: z.string().uuid(),
  items: z.array(z.object({ sku: z.string(), qty: z.number().int().positive() })).min(1),
});
async function processOrder(raw: unknown) {
  const order = OrderSchema.parse(raw);
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

**Red Flags:**
- Optional service failure causes a 500 on the core endpoint
- No timeout on optional service calls — slow dependency stalls the entire response
- Fallback returns misleading data (stale cache not labeled as such)
- No monitoring when degraded mode is active

**TypeScript:**
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

**Red Flags:**
- No global `unhandledRejection` / `uncaughtException` handler — process crashes silently
- React component tree with no `ErrorBoundary` — one render error unmounts the entire UI
- Message consumer crashes on a bad message without dead-lettering it

**TypeScript (Node.js):**
```typescript
process.on('unhandledRejection', (r) => { logger.error('Unhandled rejection', r); process.exit(1); });
process.on('uncaughtException', (e) => { logger.error('Uncaught exception', e); process.exit(1); });
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

**Red Flags:**
- Method returns `null` instead of `Optional` — callers forget to null-check
- `Optional.get()` called without `isPresent()` — same risk as null dereference
- `?.` chains so long that the failure point is invisible

**Java:**
```java
// BEFORE — null return; caller forgets check, NPE in production
public User findUser(String id) { return userMap.get(id); }

// AFTER — Optional forces caller to handle absence
public Optional<User> findUser(String id) { return Optional.ofNullable(userMap.get(id)); }
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

**Red Flags:**
- Failed messages acknowledged and discarded — data loss with no audit trail
- No retry limit — bad message retried indefinitely, blocking the queue
- DLQ exists but is never monitored — unprocessable messages accumulate silently

**TypeScript (SQS):**
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
| **Pokemon Exception Handling** | `catch(e) {}` — catches everything, handles nothing | Handle specific errors; re-throw what you cannot handle |
| **Error Swallowing** | `catch(e) { log(e); }` without re-throwing | Decide: recover, rethrow, or convert to Result |
| **String-Typed Errors** | `throw "something went wrong"` | Always throw typed `Error` objects |
| **Control Flow via Exceptions** | Using try/catch for expected conditions | Use Result types or explicit checks |
| **Log and Throw** | Log then re-throw — duplicate log entries | Log ONCE at the boundary; lower layers wrap without logging |
| **Overly Broad Catch** | Catching `Exception` when only `IOException` expected | Catch the most specific type |
| **Silent Null Return** | Returning `null` from a method that "failed" | Return `Optional`, `Result`, or throw typed exception |
| **Retry Without Idempotency** | Retrying `POST /charge` — double charge | Verify idempotency; use idempotency keys |

**Pokemon Exception Handling — TypeScript fix:**
```typescript
// WRONG: try { return await fetchUser(id); } catch (e) {}
// CORRECT — handle expected, propagate the rest
async function loadUser(id: string): Promise<User | null> {
  try { return await fetchUser(id); }
  catch (err) {
    if (err instanceof NotFoundError) return null;
    throw err;
  }
}
```

---

## Cross-References

- `concurrency-patterns` — Async/Await Pitfalls: unobserved promise rejections and fire-and-forget tasks
- `refactor-functional-patterns` — Monadic error handling: `map`, `flatMap`, `chain` over Result/Option types
- `review-code-quality-process` — Error handling checklist: patterns here, review workflow there
- `detect-code-smells` — "Shotgun Surgery": scattered try/catch blocks indicate a missing centralized error boundary
