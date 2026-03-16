---
name: caching-strategies
description: Use when designing or reviewing caching layers — covers cache-aside/read-through/write-through/write-behind patterns, cache stampede and thundering herd prevention, CDN caching with Cache-Control headers, eviction policies (LRU/LFU/TTL/adaptive), multi-layer cache architecture, cache invalidation strategies, and anti-patterns with red flags across TypeScript, Go, Python, and Redis CLI
---

# Caching Strategies

## Overview

Poorly designed caches cause data staleness, thundering herds on cold starts, unbounded memory growth, and invalidation bugs that silently serve wrong data for hours. Use this guide when designing a new cache layer, reviewing caching code, or debugging performance regressions tied to cache misuse.

**When to use:** Adding caching to a service or API; reviewing code that reads from Redis, Memcached, or an in-process store; evaluating CDN configuration; auditing memory usage of long-running processes; troubleshooting stale-data incidents.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Cache-Aside | App checks cache, falls back to DB, populates cache | No TTL set; stale data served indefinitely |
| Read-Through | Cache layer fetches from DB automatically on miss | Miss storms on cold start; no stampede protection |
| Write-Through | Write hits cache and DB synchronously | Write latency doubles; inconsistency if either fails |
| Write-Behind | Write hits cache, DB updated asynchronously | Data loss if cache crashes before flush |
| Stampede / Thundering Herd | Many callers race on a single cold key | All callers hit DB simultaneously on expiry |
| Singleflight / Mutex | One caller fetches; others wait for that result | Lock contention if fetch is slow |
| CDN / Cache-Control | Edge caches static and semi-static responses | Missing `stale-while-revalidate`; over-aggressive purging |
| LRU / LFU / TTL Eviction | Remove entries by recency, frequency, or age | Unbounded cache size; wrong eviction policy for access pattern |
| Multi-Layer Cache | L1 in-process, L2 distributed, L3 CDN | L1/L2 inconsistency; missing invalidation at each layer |
| Event-Based Invalidation | Domain events trigger targeted cache evictions | Missed event; stale data blindness after writes |
| Versioned Keys | Key includes version or content hash | Old keys accumulate; no expiry on versioned entries |

---

## Patterns in Detail

### 1. Cache-Aside (Lazy Loading)

The application owns the cache interaction: check cache first, fetch from the source of truth on a miss, then populate the cache.

**Red Flags:**
- No TTL on the key — stale data served indefinitely after the underlying record changes
- Cache population inside a transaction — cache and DB can diverge if the transaction rolls back
- Cache key not namespaced — collisions across environments or tenants
- No negative caching — every miss for a non-existent key hammers the DB

**TypeScript:**
```typescript
async function getUser(id: string): Promise<User | null> {
  const cacheKey = `user:v1:${id}`;
  const cached = await redis.get(cacheKey);
  if (cached !== null) return JSON.parse(cached) as User;

  const user = await db.users.findById(id);
  if (user) {
    await redis.set(cacheKey, JSON.stringify(user), 'EX', 300); // 5-min TTL
  } else {
    await redis.set(cacheKey, 'null', 'EX', 30); // negative cache: 30s
  }
  return user;
}
```

**Go:**
```go
func GetUser(ctx context.Context, id string) (*User, error) {
    key := fmt.Sprintf("user:v1:%s", id)
    val, err := rdb.Get(ctx, key).Result()
    if err == nil {
        var u User
        if err := json.Unmarshal([]byte(val), &u); err == nil {
            return &u, nil
        }
    }
    user, err := db.FindUserByID(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("GetUser(%s): %w", id, err)
    }
    data, _ := json.Marshal(user)
    rdb.Set(ctx, key, data, 5*time.Minute)
    return user, nil
}
```

**Redis CLI — verify TTL is set:**
```bash
TTL user:v1:abc123   # should return > 0; -1 means no expiry (bug)
```

---

### 2. Read-Through and Write-Through Patterns

**Read-Through** delegates the cache-miss fetch to the cache layer itself (e.g., a library or proxy). The application always reads from the cache.

**Write-Through** writes to the cache and the backing store in the same operation, keeping them in sync at write time.

**Red Flags — Read-Through:**
- No stampede protection on cold start — all callers fire the backing-store fetch simultaneously
- Read-through layer lacks circuit-breaker — DB failure bypasses cache entirely

**Red Flags — Write-Through:**
- Write latency spikes because both cache and DB must acknowledge before returning
- Partial failure: cache write succeeds but DB write fails (or vice versa) — use transactions or sagas to recover
- Write-through on infrequently read data — wasteful to cache data that may never be read

**Python — write-through with Redis and Postgres:**
```python
def update_user(user_id: str, data: dict) -> User:
    with db.transaction():
        user = db.users.update(user_id, data)   # persist first
        cache_key = f"user:v1:{user_id}"
        redis.set(cache_key, json.dumps(user.to_dict()), ex=300)
    return user  # both succeed or neither does (via transaction rollback)
```

**TypeScript — read-through wrapper:**
```typescript
class ReadThroughCache<T> {
  constructor(
    private readonly fetch: (key: string) => Promise<T>,
    private readonly ttlSeconds: number,
  ) {}

  async get(key: string): Promise<T> {
    const cached = await redis.get(key);
    if (cached !== null) return JSON.parse(cached) as T;
    const value = await this.fetch(key);           // delegates to backing store
    await redis.set(key, JSON.stringify(value), 'EX', this.ttlSeconds);
    return value;
  }
}
```

---

### 3. Write-Behind (Write-Back)

Writes land in the cache immediately and are flushed to the backing store asynchronously. Reduces write latency at the cost of durability.

**Red Flags:**
- Cache node crashes before flush — data loss with no recovery path
- Flush queue grows unboundedly under write bursts — OOM risk
- Write-behind used for financial or audit records — wrong durability trade-off
- No ordered flush — later write overwritten by an earlier queued write

**Go — write-behind with buffered flush:**
```go
type WriteBehindCache struct {
    mu      sync.Mutex
    pending map[string]User
    flush   func(users []User) error
}

func (c *WriteBehindCache) Set(u User) {
    c.mu.Lock()
    c.pending[u.ID] = u   // latest write wins per key
    c.mu.Unlock()
}

func (c *WriteBehindCache) FlushLoop(ctx context.Context, interval time.Duration) {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()
    for {
        select {
        case <-ticker.C:
            c.mu.Lock()
            batch := maps.Values(c.pending)
            c.pending = make(map[string]User)
            c.mu.Unlock()
            if len(batch) > 0 {
                if err := c.flush(batch); err != nil {
                    // re-queue or alert — never silently drop
                }
            }
        case <-ctx.Done():
            return
        }
    }
}
```

---

### 4. Cache Stampede and Thundering Herd Prevention

When a popular key expires, all concurrent callers find a cache miss and simultaneously query the backing store. This thundering herd can overwhelm the DB and cascade into an outage.

**Red Flags:**
- No mutex or singleflight around cache population — 100 goroutines hit the DB at once
- All keys share the same TTL — mass expiry causes periodic stampedes
- No probabilistic early expiration — surprise stampedes at exact TTL boundary

**Singleflight pattern — Go:**
```go
import "golang.org/x/sync/singleflight"

var sfGroup singleflight.Group

func GetProduct(ctx context.Context, id string) (*Product, error) {
    key := "product:" + id
    result, err, _ := sfGroup.Do(key, func() (interface{}, error) {
        // Only ONE goroutine executes this block; others wait and share the result
        p, err := db.FindProduct(ctx, id)
        if err != nil { return nil, err }
        rdb.Set(ctx, key, mustMarshal(p), 5*time.Minute)
        return p, nil
    })
    if err != nil { return nil, err }
    return result.(*Product), nil
}
```

**Mutex-based stampede guard — TypeScript:**
```typescript
const inflightRequests = new Map<string, Promise<unknown>>();

async function getWithLock<T>(key: string, fetch: () => Promise<T>, ttl: number): Promise<T> {
  const cached = await redis.get(key);
  if (cached !== null) return JSON.parse(cached) as T;

  if (!inflightRequests.has(key)) {
    const promise = fetch().then(async (val) => {
      await redis.set(key, JSON.stringify(val), 'EX', ttl);
      inflightRequests.delete(key);
      return val;
    }).catch((err) => { inflightRequests.delete(key); throw err; });
    inflightRequests.set(key, promise);
  }
  return inflightRequests.get(key) as Promise<T>;
}
```

**Jitter to stagger expiry:**
```python
import random

def set_with_jitter(redis_client, key: str, value: str, base_ttl: int, jitter: int = 30):
    """Add random jitter to prevent synchronized mass expiry."""
    ttl = base_ttl + random.randint(0, jitter)
    redis_client.set(key, value, ex=ttl)
```

**Redis CLI — probabilistic early refresh (XFetch algorithm):**
```bash
# Read value plus stored expiry time; refresh if within probabilistic window
# Implemented in application layer — not a native Redis command
```

---

### 5. CDN Caching and Cache-Control Headers

HTTP caching at the CDN edge reduces origin load and latency. Correct `Cache-Control` directives are critical for correctness and performance.

**Red Flags:**
- `Cache-Control: no-store` on publicly cacheable assets — unnecessary origin hits
- No `stale-while-revalidate` — users wait for full round-trip on every revalidation
- `Cache-Control: max-age=0` paired with no `ETag`/`Last-Modified` — every request validates but headers are wrong
- Missing `Vary: Accept-Encoding` on compressed responses — CDN serves wrong encoding to some clients
- Caching authenticated API responses without `Cache-Control: private` — data leakage between users

**Common directives:**

| Directive | Meaning |
|-----------|---------|
| `max-age=N` | Cache for N seconds (client + CDN) |
| `s-maxage=N` | CDN-only max age (overrides `max-age` for shared caches) |
| `stale-while-revalidate=N` | Serve stale content for N seconds while fetching fresh in background |
| `stale-if-error=N` | Serve stale for N seconds if origin returns 5xx |
| `no-cache` | Must revalidate with origin before serving (not "don't cache") |
| `no-store` | Never store the response in any cache |
| `private` | Browser may cache; CDN must not |
| `immutable` | Resource will never change; skip revalidation for `max-age` duration |

**TypeScript — Express headers for a product API:**
```typescript
app.get('/products/:id', async (req, res) => {
  const product = await getProduct(req.params.id);
  res
    .set('Cache-Control', 'public, s-maxage=60, stale-while-revalidate=30, stale-if-error=300')
    .set('ETag', hashProduct(product))
    .json(product);
});

// Static assets — long TTL with immutable (content-addressed filename)
app.use('/static', express.static('dist', {
  maxAge: '1y',
  setHeaders: (res) => res.set('Cache-Control', 'public, max-age=31536000, immutable'),
}));
```

**CDN purge on update — Python:**
```python
import httpx

def purge_cdn_key(path: str) -> None:
    """Purge a single path from the CDN after a write."""
    resp = httpx.post(
        f"https://api.cdn-provider.com/purge",
        json={"paths": [path]},
        headers={"Authorization": f"Bearer {CDN_API_TOKEN}"},
        timeout=5.0,
    )
    resp.raise_for_status()
```

---

### 6. Eviction Policies

When the cache reaches capacity, an eviction policy decides which entries to remove. Choosing the wrong policy wastes memory and degrades hit rates.

**Red Flags:**
- Default Redis `noeviction` policy — writes fail under memory pressure instead of evicting entries
- LRU applied to a scan-heavy workload — recently scanned cold data evicts hot frequently accessed data
- No TTL on any key — cache grows unboundedly until OOM
- Eviction policy set globally but not tuned per key namespace

**Policy Comparison:**

| Policy | Evicts | Best For |
|--------|--------|----------|
| LRU (Least Recently Used) | Oldest last-accessed entry | General-purpose caches with recency-biased access |
| LFU (Least Frequently Used) | Least-accessed entry over time | Workloads with clear hot/cold data split |
| TTL-based | Oldest by remaining TTL | Content caches where freshness is the primary concern |
| Random | Random entry | Very high throughput where approximation is acceptable |
| Adaptive (ARC, W-TinyLFU) | Balances recency and frequency | Mixed workloads; used by Caffeine (Java), Ristretto (Go) |

**Redis — configure eviction policy:**
```bash
# Set in redis.conf or at runtime:
CONFIG SET maxmemory 512mb
CONFIG SET maxmemory-policy allkeys-lru   # evict any key by LRU when full
# Other options: allkeys-lfu, volatile-lru, volatile-lfu, volatile-ttl, noeviction
```

**Go — Ristretto (W-TinyLFU adaptive cache):**
```go
import "github.com/dgraph-io/ristretto"

cache, _ := ristretto.NewCache(&ristretto.Config{
    NumCounters: 1e7,     // track frequency for 10M keys
    MaxCost:     1 << 30, // 1 GB max
    BufferItems: 64,
})

cache.Set("product:123", product, 1)  // cost=1 item
cache.Wait()

if val, ok := cache.Get("product:123"); ok {
    return val.(*Product), nil
}
```

**Python — LRU with functools:**
```python
from functools import lru_cache

@lru_cache(maxsize=1024)
def get_country_name(code: str) -> str:
    return country_db.lookup(code)   # expensive lookup cached in-process
```

---

### 7. Multi-Layer Cache Architecture

Production systems typically use three cache layers. Each layer trades latency, capacity, and consistency differently.

| Layer | Type | Latency | Capacity | Consistency |
|-------|------|---------|----------|-------------|
| L1 — In-Process | Thread-local / heap map | < 1 ms | MBs | Per-instance; invalidation is hard |
| L2 — Distributed | Redis / Memcached | 1–5 ms | GBs | Shared across instances |
| L3 — CDN | Edge nodes | < 50 ms (edge hit) | TBs | Eventual; purge-based |

**Red Flags:**
- L1 cache not invalidated when L2 entry is evicted or updated — instances serve divergent data
- L1 cache shared across threads without synchronization — race conditions
- No fallback when L2 (Redis) is unavailable — entire request fails instead of going to DB
- L3 CDN caching private or user-specific responses — cross-user data leakage

**TypeScript — layered get with L1 then L2 then DB:**
```typescript
const l1Cache = new Map<string, { value: unknown; expiresAt: number }>();

async function getLayered<T>(key: string, fetch: () => Promise<T>, ttlMs: number): Promise<T> {
  // L1 check
  const l1 = l1Cache.get(key);
  if (l1 && l1.expiresAt > Date.now()) return l1.value as T;

  // L2 check (Redis)
  const l2 = await redis.get(key);
  if (l2 !== null) {
    const value = JSON.parse(l2) as T;
    l1Cache.set(key, { value, expiresAt: Date.now() + ttlMs / 2 }); // shorter L1 TTL
    return value;
  }

  // DB fetch
  const value = await fetch();
  await redis.set(key, JSON.stringify(value), 'EX', Math.floor(ttlMs / 1000));
  l1Cache.set(key, { value, expiresAt: Date.now() + ttlMs / 2 });
  return value;
}
```

---

### 8. Cache Invalidation Strategies

Invalidation is the hardest part of caching. Three main strategies: time-based, event-based, and versioned keys.

**Red Flags:**
- No invalidation strategy — stale data blindness after writes; users see outdated records
- Invalidating by scanning key patterns (`KEYS user:*`) in production Redis — O(N) blocks the server
- Event-based invalidation without idempotency — duplicate events cause double invalidation churn
- Versioned keys without expiry — old versioned keys accumulate, exhausting memory

**Time-Based Invalidation:**
```python
# Accept some staleness; TTL controls maximum stale window
redis.set("catalog:featured", json.dumps(products), ex=600)  # stale up to 10 min
```

**Event-Based Invalidation — TypeScript with an event bus:**
```typescript
// Publisher: emit event after DB write
async function updateProduct(id: string, patch: Partial<Product>): Promise<Product> {
  const updated = await db.products.update(id, patch);
  await eventBus.publish('product.updated', { id });  // trigger invalidation
  return updated;
}

// Subscriber: invalidate on event
eventBus.subscribe('product.updated', async ({ id }: { id: string }) => {
  await redis.del(`product:v1:${id}`);
  await redis.del(`catalog:featured`);  // also bust aggregate keys
});
```

**Versioned Keys — bust without explicit delete:**
```typescript
// Version stored in a separate key or config; bump version to invalidate
const CATALOG_VERSION = await redis.get('catalog:version') ?? '1';
const cacheKey = `catalog:v${CATALOG_VERSION}:featured`;

// To invalidate all catalog entries: increment the version key
await redis.incr('catalog:version');
// Old keys become unreachable and expire via TTL
```

**Redis CLI — targeted delete (safe alternative to KEYS):**
```bash
# Use SCAN with MATCH for batch deletes — non-blocking
redis-cli --scan --pattern "product:v1:*" | xargs redis-cli del
```

---

### 9. Caching Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Cache Everything** | Every DB query result is cached regardless of access frequency | Cache only data with high read-to-write ratio and measurable latency impact |
| **No TTL** | Keys set without expiry; stale data survives forever | Always set a TTL; use short TTLs for frequently updated data |
| **Unbounded Cache** | In-process map or cache with no size limit; memory grows until OOM | Set `maxSize` or `MaxCost`; choose an eviction policy |
| **Stale Data Blindness** | Writes go to the DB; cache never invalidated; reads serve wrong data | Implement event-based or write-through invalidation |
| **Cache Stampede Ignored** | Popular key expires; all callers hammer the DB simultaneously | Use singleflight, mutex, or probabilistic early refresh |
| **Caching Mutable Aggregates** | Complex object cached; partial update invalidates only part of it | Cache fine-grained entities; rebuild aggregates at read time |
| **Hot Key Bottleneck** | Single Redis key receives millions of reads/sec; becomes a bottleneck | Shard hot keys with a suffix (e.g., `key:shard:{0..N}`); use local L1 replica |
| **Bypassing Cache on Write** | App writes directly to DB without updating or evicting the cache key | Always evict or update cache on write; never leave a stale key alive |

**Hot Key Sharding — Go:**
```go
const numShards = 8

func hotKeyGet(ctx context.Context, base string) (string, error) {
    shard := rand.Intn(numShards)
    key := fmt.Sprintf("%s:shard:%d", base, shard)
    val, err := rdb.Get(ctx, key).Result()
    if err == redis.Nil {
        // miss: fetch and populate this shard
        return populateShard(ctx, base, key)
    }
    return val, err
}
```

**Bounded in-process cache — Python:**
```python
from cachetools import LRUCache, cached
from threading import RLock

_cache: LRUCache = LRUCache(maxsize=500)
_lock = RLock()

@cached(cache=_cache, lock=_lock)
def get_config(tenant_id: str) -> dict:
    return db.configs.find_one(tenant_id)
```

---

## Cross-References

- `performance-anti-patterns` — N+1 queries, unbounded result sets, and missing indexes that caching may mask but not fix
- `microservices-resilience-patterns` — Circuit breaker and retry patterns to protect backing stores when cache is cold
- `database-review-patterns` — Query optimization and connection pool sizing that interacts with cache miss rates

---

## Appendix: Redis Key Design Checklist

Before caching any new entity:

- [ ] Key includes namespace, version, and entity ID: `{service}:{entity}:v{N}:{id}`
- [ ] TTL always set — never use `SET` without `EX` or `PX`
- [ ] Negative cache entries set with shorter TTL to prevent DB hammering on missing keys
- [ ] Stampede protection in place for any key with high concurrent read pressure
- [ ] Eviction policy reviewed for the Redis instance (not left as `noeviction`)
- [ ] Invalidation path tested — a write to the DB must evict or refresh the cached entry
- [ ] Hot key analysis done if key is expected to handle > 10k reads/sec
