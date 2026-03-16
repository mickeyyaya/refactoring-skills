---
name: api-rate-limiting-throttling
description: Use when designing or reviewing rate limiting implementations — covers Token Bucket, Leaky Bucket, Sliding Window Counter, Fixed Window Counter, distributed Redis-based limiting with Lua scripts, response headers, client-side throttling/backoff, and anti-patterns across TypeScript, Go, Python, and Redis Lua
---

# API Rate Limiting and Throttling

## Overview

Rate limiting protects services from traffic spikes, abuse, and accidental overload. Choosing the wrong algorithm leads to either boundary spikes that allow bursting through limits, or excessive rejection of legitimate traffic. Use this guide to implement, review, or debug rate limiting logic.

**When to use:** Designing public or internal APIs; reviewing middleware for throttling correctness; evaluating Redis-based distributed limiting; auditing rate limit response headers; checking client-side retry and backoff behavior.

## Quick Reference

| Algorithm | Burst Tolerance | Accuracy | Complexity | Best For |
|-----------|----------------|----------|------------|----------|
| Token Bucket | High — refills at rate R, allows bursts up to capacity C | Good | Medium | APIs that allow short bursts |
| Leaky Bucket | None — constant drain rate | Good | Medium | Smoothing traffic to downstream |
| Sliding Window Counter | High — no boundary spikes | Excellent | Medium-High | Accurate per-user limits |
| Fixed Window Counter | Medium — full quota resets at boundary | Fair | Low | Simple counters, background jobs |
| Distributed (Redis Lua) | Configurable | Excellent | High | Multi-instance production APIs |

---

## Patterns in Detail

### 1. Token Bucket Algorithm

The token bucket holds up to `capacity` tokens. Tokens are added at `refillRate` per second. Each request consumes one token. Requests that arrive when the bucket is empty are rejected or queued.

**Red Flags:**
- Storing last-refill timestamp as an integer — truncation error accumulates over time
- Not capping tokens at capacity — bucket grows unboundedly after idle periods
- Per-process in-memory state in multi-instance deployments — each instance has a full bucket

**TypeScript:**
```typescript
interface TokenBucket {
  tokens: number;
  lastRefillMs: number;
  readonly capacity: number;
  readonly refillRatePerMs: number;
}

function createTokenBucket(capacity: number, refillRatePerSecond: number): TokenBucket {
  return {
    tokens: capacity,
    lastRefillMs: Date.now(),
    capacity,
    refillRatePerMs: refillRatePerSecond / 1000,
  };
}

function consumeToken(bucket: TokenBucket): { allowed: boolean; bucket: TokenBucket } {
  const now = Date.now();
  const elapsed = now - bucket.lastRefillMs;
  const refilled = Math.min(
    bucket.capacity,
    bucket.tokens + elapsed * bucket.refillRatePerMs,
  );
  if (refilled < 1) {
    return { allowed: false, bucket: { ...bucket, tokens: refilled, lastRefillMs: now } };
  }
  return { allowed: true, bucket: { ...bucket, tokens: refilled - 1, lastRefillMs: now } };
}
```

**Go:**
```go
type TokenBucket struct {
    mu             sync.Mutex
    tokens         float64
    lastRefill     time.Time
    capacity       float64
    refillPerSecond float64
}

func (b *TokenBucket) Allow() bool {
    b.mu.Lock()
    defer b.mu.Unlock()
    now := time.Now()
    elapsed := now.Sub(b.lastRefill).Seconds()
    b.tokens = math.Min(b.capacity, b.tokens+elapsed*b.refillPerSecond)
    b.lastRefill = now
    if b.tokens < 1 {
        return false
    }
    b.tokens--
    return true
}
```

---

### 2. Leaky Bucket Algorithm

The leaky bucket queues incoming requests and drains them at a constant rate. It produces a smooth, steady output stream regardless of bursty input. Use it when downstream services need stable call rates.

**Red Flags:**
- Queue grows without bound — memory exhaustion under sustained overload
- Drain goroutine/timer leak when bucket is garbage-collected
- Using leaky bucket where burst tolerance is required — it rejects all bursts

**Python:**
```python
import time
import threading
from collections import deque

class LeakyBucket:
    def __init__(self, rate_per_second: float, capacity: int) -> None:
        self._rate = rate_per_second
        self._capacity = capacity
        self._queue: deque = deque()
        self._lock = threading.Lock()
        self._last_leak = time.monotonic()

    def add_request(self, request: object) -> bool:
        """Returns True if request was accepted into the queue."""
        with self._lock:
            self._leak()
            if len(self._queue) >= self._capacity:
                return False
            self._queue.append(request)
            return True

    def _leak(self) -> None:
        now = time.monotonic()
        elapsed = now - self._last_leak
        leaked = int(elapsed * self._rate)
        for _ in range(min(leaked, len(self._queue))):
            self._queue.popleft()
        if leaked > 0:
            self._last_leak = now
```

**Go:**
```go
// LeakyBucket using time.Ticker for constant drain
type LeakyBucket struct {
    in  chan struct{}
    out chan struct{}
}

func NewLeakyBucket(ratePerSecond int, capacity int) *LeakyBucket {
    lb := &LeakyBucket{
        in:  make(chan struct{}, capacity),
        out: make(chan struct{}, capacity),
    }
    ticker := time.NewTicker(time.Second / time.Duration(ratePerSecond))
    go func() {
        for range ticker.C {
            select {
            case req := <-lb.in:
                lb.out <- req
            default:
            }
        }
    }()
    return lb
}

func (lb *LeakyBucket) Allow() bool {
    select {
    case lb.in <- struct{}{}:
        return true
    default:
        return false
    }
}
```

---

### 3. Sliding Window Counter

Splits time into sub-windows (e.g., 60 one-second buckets for a 60-second limit). Each request increments the current sub-window. The total is the sum across all sub-windows in the range. Eliminates the boundary-spike vulnerability of fixed windows.

**Red Flags:**
- Sub-window count too low — approaches fixed-window accuracy, boundary spikes reappear
- Not expiring old sub-windows — unbounded memory growth
- No atomic increment in distributed context — race conditions under high concurrency

**TypeScript:**
```typescript
class SlidingWindowCounter {
  private readonly buckets: Map<number, number> = new Map();

  constructor(
    private readonly windowMs: number,
    private readonly bucketCount: number,
    private readonly limit: number,
  ) {}

  private getBucketKey(now: number): number {
    const bucketSizeMs = this.windowMs / this.bucketCount;
    return Math.floor(now / bucketSizeMs);
  }

  isAllowed(now: number = Date.now()): boolean {
    const currentKey = this.getBucketKey(now);
    const windowStart = now - this.windowMs;

    // Prune expired buckets
    for (const key of this.buckets.keys()) {
      if (key * (this.windowMs / this.bucketCount) < windowStart) {
        this.buckets.delete(key);
      }
    }

    // Sum all active buckets
    let total = 0;
    for (const [key, count] of this.buckets) {
      if (key * (this.windowMs / this.bucketCount) >= windowStart) {
        total += count;
      }
    }

    if (total >= this.limit) return false;
    this.buckets.set(currentKey, (this.buckets.get(currentKey) ?? 0) + 1);
    return true;
  }
}
```

**Redis (pipeline-based sliding window):**
```redis
-- Sliding window using sorted set
-- Key: rate:<user_id>, Score: timestamp, Member: unique request ID
ZADD rate:user123 <timestamp_ms> <uuid>
ZREMRANGEBYSCORE rate:user123 0 <timestamp_ms - window_ms>
ZCARD rate:user123
EXPIRE rate:user123 <window_seconds + 1>
```

---

### 4. Fixed Window Counter

Counts requests in discrete time windows (e.g., "100 requests per minute"). Simple and fast, but vulnerable to a boundary spike: a client can fire 100 requests at 11:59:59 and another 100 at 12:00:00, effectively sending 200 in two seconds.

**Red Flags:**
- No EXPIRE on the counter key — counter never resets, permanently blocks traffic
- Window key collisions across users — all users share one counter
- Not handling atomic increment-and-check — race between INCR and comparison

**Go:**
```go
type FixedWindowRateLimiter struct {
    redisClient *redis.Client
    limit       int
    windowSize  time.Duration
}

func (r *FixedWindowRateLimiter) Allow(ctx context.Context, key string) (bool, error) {
    windowKey := fmt.Sprintf("ratelimit:%s:%d",
        key, time.Now().Truncate(r.windowSize).Unix())

    pipe := r.redisClient.Pipeline()
    incr := pipe.Incr(ctx, windowKey)
    pipe.Expire(ctx, windowKey, r.windowSize+time.Second)
    if _, err := pipe.Exec(ctx); err != nil {
        return false, fmt.Errorf("FixedWindowRateLimiter.Allow: %w", err)
    }
    return incr.Val() <= int64(r.limit), nil
}
```

**Python:**
```python
import redis
import time

def fixed_window_allow(r: redis.Redis, key: str, limit: int, window_seconds: int) -> bool:
    window_key = f"ratelimit:{key}:{int(time.time()) // window_seconds}"
    pipe = r.pipeline()
    pipe.incr(window_key)
    pipe.expire(window_key, window_seconds + 1)
    results = pipe.execute()
    count = results[0]
    return count <= limit
```

---

### 5. Distributed Rate Limiting with Redis Lua Scripts

Atomic Lua scripts execute on a single Redis node without interleaving. This guarantees check-and-increment is atomic — no race conditions under high concurrency, unlike a pipeline of separate INCR + GET commands.

**Red Flags:**
- Using MULTI/EXEC (optimistic lock) instead of Lua — WATCH failures require client-side retry loops
- Lua script with too many keys — blocked during execution, Redis is single-threaded
- Not setting EXPIRE inside the Lua script — counter persists forever on first-time creation
- Calling SCRIPT LOAD repeatedly — cache the SHA and use EVALSHA

**Redis Lua — Token Bucket (atomic):**
```lua
-- KEYS[1]: bucket key  ARGV[1]: capacity  ARGV[2]: refill_rate/sec
-- ARGV[3]: now (unix ms)  ARGV[4]: cost (tokens to consume)
local key      = KEYS[1]
local capacity = tonumber(ARGV[1])
local rate     = tonumber(ARGV[2])
local now      = tonumber(ARGV[3])
local cost     = tonumber(ARGV[4])

local data = redis.call("HMGET", key, "tokens", "last_refill")
local tokens     = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now

local elapsed = math.max(0, now - last_refill)
local refilled = math.min(capacity, tokens + (elapsed / 1000) * rate)

if refilled < cost then
  redis.call("HMSET", key, "tokens", refilled, "last_refill", now)
  redis.call("PEXPIRE", key, math.ceil(capacity / rate * 1000) + 1000)
  return {0, math.ceil((cost - refilled) / rate * 1000)}  -- {allowed=0, retry_after_ms}
end

redis.call("HMSET", key, "tokens", refilled - cost, "last_refill", now)
redis.call("PEXPIRE", key, math.ceil(capacity / rate * 1000) + 1000)
return {1, 0}  -- {allowed=1, retry_after_ms=0}
```

**TypeScript — loading and calling the Lua script:**
```typescript
import { createClient } from 'redis';

const TOKEN_BUCKET_SCRIPT = `
  -- (paste Lua script above)
`;

class RedisRateLimiter {
  private scriptSha: string | null = null;

  constructor(
    private readonly redis: ReturnType<typeof createClient>,
    private readonly capacity: number,
    private readonly refillRatePerSecond: number,
  ) {}

  async loadScript(): Promise<void> {
    this.scriptSha = await this.redis.scriptLoad(TOKEN_BUCKET_SCRIPT);
  }

  async allow(key: string, cost = 1): Promise<{ allowed: boolean; retryAfterMs: number }> {
    const now = Date.now();
    const [allowed, retryAfterMs] = await this.redis.evalSha(this.scriptSha!, {
      keys: [`ratelimit:${key}`],
      arguments: [
        String(this.capacity),
        String(this.refillRatePerSecond),
        String(now),
        String(cost),
      ],
    }) as [number, number];
    return { allowed: allowed === 1, retryAfterMs };
  }
}
```

**Go — using go-redis with EVALSHA:**
```go
func (r *RedisRateLimiter) Allow(ctx context.Context, key string) (bool, int64, error) {
    now := time.Now().UnixMilli()
    result, err := r.client.EvalSha(ctx, r.scriptSHA,
        []string{fmt.Sprintf("ratelimit:%s", key)},
        r.capacity, r.refillRate, now, 1,
    ).Int64Slice()
    if err != nil {
        return false, 0, fmt.Errorf("RedisRateLimiter.Allow: %w", err)
    }
    return result[0] == 1, result[1], nil
}
```

Cross-reference: `caching-strategies` — Redis data structures and EXPIRE management patterns.

---

### 6. Rate Limit Response Headers

Standard headers let clients self-throttle rather than hitting 429s. Always include them on every response, not only on rejection.

**Red Flags:**
- Headers only set on 429 responses — clients cannot proactively back off
- `X-RateLimit-Reset` as a Unix timestamp without documentation — ambiguous (ms vs seconds)
- Missing `Retry-After` on 429 — clients cannot know how long to wait
- `Retry-After` value too large — legitimate clients give up permanently

**Standard Headers:**

| Header | Value | Example |
|--------|-------|---------|
| `X-RateLimit-Limit` | Total requests allowed in window | `100` |
| `X-RateLimit-Remaining` | Requests left in current window | `42` |
| `X-RateLimit-Reset` | Unix timestamp (seconds) when window resets | `1716912000` |
| `Retry-After` | Seconds to wait before retrying (on 429) | `30` |

**TypeScript (Express middleware):**
```typescript
import { Request, Response, NextFunction } from 'express';

interface RateLimitInfo {
  limit: number;
  remaining: number;
  resetAtUnixSec: number;
  retryAfterSec?: number;
}

function setRateLimitHeaders(res: Response, info: RateLimitInfo): void {
  res.set('X-RateLimit-Limit', String(info.limit));
  res.set('X-RateLimit-Remaining', String(Math.max(0, info.remaining)));
  res.set('X-RateLimit-Reset', String(info.resetAtUnixSec));
  if (info.retryAfterSec !== undefined) {
    res.set('Retry-After', String(info.retryAfterSec));
  }
}

function rateLimitMiddleware(limiter: RedisRateLimiter) {
  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    const key = req.ip ?? 'unknown';
    const { allowed, retryAfterMs } = await limiter.allow(key);
    const resetAtUnixSec = Math.ceil((Date.now() + retryAfterMs) / 1000);

    setRateLimitHeaders(res, {
      limit: limiter.capacity,
      remaining: allowed ? limiter.capacity - 1 : 0,
      resetAtUnixSec,
      retryAfterSec: allowed ? undefined : Math.ceil(retryAfterMs / 1000),
    });

    if (!allowed) {
      res.status(429).json({ error: 'Too Many Requests', retryAfterSec: Math.ceil(retryAfterMs / 1000) });
      return;
    }
    next();
  };
}
```

**Go:**
```go
func (m *RateLimitMiddleware) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    allowed, retryAfterMs, _ := m.limiter.Allow(r.Context(), r.RemoteAddr)
    resetAt := time.Now().Add(time.Duration(retryAfterMs) * time.Millisecond).Unix()
    w.Header().Set("X-RateLimit-Limit", strconv.Itoa(m.capacity))
    w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(resetAt, 10))
    if !allowed {
        w.Header().Set("Retry-After", strconv.FormatInt(int64(retryAfterMs/1000)+1, 10))
        w.Header().Set("X-RateLimit-Remaining", "0")
        http.Error(w, "Too Many Requests", http.StatusTooManyRequests)
        return
    }
    w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(m.capacity-1))
    m.next.ServeHTTP(w, r)
}
```

---

### 7. Client-Side Throttling and Backoff

Clients that ignore 429s and retry immediately cause thundering herd scenarios and can trigger secondary outages. Proper backoff with jitter spreads retries over time.

**Red Flags:**
- Retrying immediately on 429 — amplifies load during outage
- Ignoring `Retry-After` header — server-specified wait time is discarded
- Exponential backoff without jitter — synchronized retries from multiple clients
- No maximum backoff cap — delay grows unboundedly, effectively breaking the client

**TypeScript — respects `Retry-After` with jittered exponential backoff:**
```typescript
interface BackoffOptions {
  maxAttempts?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  jitter?: boolean;
}

async function fetchWithRateLimitRetry<T>(
  fn: () => Promise<Response>,
  opts: BackoffOptions = {},
): Promise<T> {
  const { maxAttempts = 5, baseDelayMs = 500, maxDelayMs = 30_000, jitter = true } = opts;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const response = await fn();
    if (response.status !== 429) {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json() as Promise<T>;
    }

    if (attempt === maxAttempts) throw new Error('Rate limit exceeded after max attempts');

    // Respect Retry-After if present, otherwise use exponential backoff
    const retryAfterHeader = response.headers.get('Retry-After');
    let delayMs = retryAfterHeader
      ? Number(retryAfterHeader) * 1000
      : Math.min(maxDelayMs, baseDelayMs * 2 ** (attempt - 1));

    if (jitter) delayMs = delayMs * (0.5 + Math.random() * 0.5);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  throw new Error('unreachable');
}
```

**Python — using `tenacity` with `Retry-After` awareness:**
```python
import time
import random
import requests
from typing import Callable, TypeVar

T = TypeVar("T")

def call_with_backoff(
    fn: Callable[[], requests.Response],
    max_attempts: int = 5,
    base_delay: float = 0.5,
    max_delay: float = 30.0,
) -> requests.Response:
    for attempt in range(1, max_attempts + 1):
        resp = fn()
        if resp.status_code != 429:
            resp.raise_for_status()
            return resp
        if attempt == max_attempts:
            raise RuntimeError(f"Rate limited after {max_attempts} attempts")

        retry_after = resp.headers.get("Retry-After")
        delay = float(retry_after) if retry_after else min(
            max_delay, base_delay * (2 ** (attempt - 1))
        )
        jittered = delay * (0.5 + random.random() * 0.5)
        time.sleep(jittered)

    raise RuntimeError("unreachable")
```

Cross-reference: `error-handling-patterns` — Retry with Exponential Backoff for general retry utilities.

---

### 8. Rate Limiting Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **In-Memory Counter with Multi-Instance** | Each process has its own counter; 10 instances = 10x the intended limit | Use Redis or another shared store for the counter |
| **Missing EXPIRE on Counter Key** | Counter created on first request but never expires; user permanently blocked after burst | Always set EXPIRE equal to the window duration |
| **No Rate Limit on Unauthenticated Endpoints** | `/login`, `/register`, `/forgot-password` left unprotected — brute force and credential stuffing | Apply strict limits (e.g., 5/min by IP) on auth endpoints |
| **Boundary Spike (Fixed Window)** | Client fires `2 * limit` requests across a window boundary in 1 second | Use sliding window or token bucket instead |
| **Rate Limiting by User-Agent or Referer** | Headers trivially spoofed | Always limit by IP, API key, or authenticated user ID |
| **Shared Limit Across All Endpoints** | Bulk import endpoint drains quota for normal API usage | Apply per-endpoint limits with separate buckets |
| **No Observability** | Rate limit events not logged or metered | Emit metrics on every 429; alert on spike in rejection rate |
| **Silent 200 with Dropped Request** | Return 200 OK but drop the request silently | Always return 429 with headers so clients can adapt |

**In-Memory Counter Anti-Pattern — TypeScript fix:**
```typescript
// WRONG: per-process map — each of 5 instances allows 100 req/min = 500 effective limit
const counters = new Map<string, number>();

// CORRECT: shared Redis counter with atomic increment and EXPIRE
async function isAllowed(redis: Redis, key: string, limit: number, windowSec: number): Promise<boolean> {
  const rKey = `rl:${key}:${Math.floor(Date.now() / 1000 / windowSec)}`;
  const count = await redis.incr(rKey);
  if (count === 1) await redis.expire(rKey, windowSec + 1);  // set EXPIRE only on creation
  return count <= limit;
}
```

**Missing EXPIRE — Redis Lua fix:**
```lua
-- Always set EXPIRE atomically with the increment
local count = redis.call("INCR", KEYS[1])
if count == 1 then
  -- First request in this window: set expiry atomically
  redis.call("EXPIRE", KEYS[1], tonumber(ARGV[1]))
end
return count
```

Cross-reference: `security-patterns-code-review` — Authentication endpoint brute-force protection; `caching-strategies` — Redis key expiry and eviction policies.

---

## Cross-References

- `microservices-resilience` — Circuit Breaker and Bulkhead patterns: combine with rate limiting to prevent overload cascades
- `security-patterns-code-review` — Brute-force protection: strict rate limits on `/login`, `/register`, `/forgot-password`
- `caching-strategies` — Redis key management: EXPIRE best practices, data structure selection (HASH vs STRING), eviction policies
- `error-handling-patterns` — Retry with Exponential Backoff: client-side retry utilities that honor `Retry-After`
- `concurrency-patterns` — Mutex and atomic operations: single-process token bucket with safe concurrent access
