---
name: performance-anti-patterns
description: Use when reviewing a PR for performance regressions, when a service is slow under load, when database query times are spiking, or when CPU or memory usage is growing unexpectedly
---

# Performance Anti-Patterns for Code Review

## Overview

Performance anti-patterns are recurring mistakes that degrade throughput, latency, or resource efficiency. They often go undetected in development and surface only under production load. This catalog focuses on signals a reviewer can spot in a PR diff.

Use alongside `anti-patterns-catalog` (structural problems) and `review-code-quality-process` (review workflow).

## When to Use

- PR touches database queries, HTTP clients, or any I/O layer
- p95 latency or memory usage increased without obvious cause
- Load testing shows non-linear scaling
- PR introduces loops, recursion, or collection transforms
- PR modifies caching logic or connection management

## Quick Reference

| Category | Anti-Pattern | Severity | Primary Signal in PR |
|----------|-------------|----------|----------------------|
| **Database** | N+1 Query | HIGH | Loop containing a query call |
| **Database** | Unbounded Data Fetching | HIGH | Missing LIMIT/pagination |
| **Database** | Improper Connection Management | HIGH | Connection created inside function |
| **I/O** | Chatty I/O | HIGH | Repeated small I/O calls in a loop |
| **I/O** | Synchronous I/O in Hot Path | HIGH | Blocking call without async/await |
| **Resilience** | Retry Storm | CRITICAL | Retry loop with no backoff or jitter |
| **Memory** | Memory Leak | HIGH | Event listener added without removal |
| **Concurrency** | Blocking the Event Loop | HIGH | CPU-heavy work on main thread |
| **Efficiency** | No Caching | MEDIUM | Identical fetch/compute on every call |
| **Efficiency** | String Concatenation in Loops | MEDIUM | `+=` on strings inside a loop |
| **Efficiency** | Over-rendering | MEDIUM | Missing memoization in render path |
| **Process** | Premature Optimization | LOW | Optimization without profiling comment |

---

## Category 1: Database Anti-Patterns

### N+1 Query

**Detection:** ORM/DB call nested inside a loop or array transform. Lazy-loading ORMs do this by default.
- Python/SQLAlchemy: `session.query` inside a loop over results
- TypeScript/Prisma/TypeORM: `findOne`/`findById` inside `Promise.all(items.map(...))`

```typescript
// BEFORE — N+1: one query per user
const users = await db.users.findAll();
for (const user of users) {
  user.orders = await db.orders.findAll({ where: { userId: user.id } });
}

// AFTER — single JOIN query
const users = await db.users.findAll({
  include: [{ model: db.orders }],
});
```

**Fix:** JOIN-based eager loading, `include`/`joinedload`, or batched query by parent IDs. For REST/GraphQL, use DataLoader-style batching.

---

### Unbounded Data Fetching

**Detection:** `findAll`, `SELECT *`, or `getAll` without `LIMIT`, `take`, or `pageSize`. Result immediately serialized to JSON signals pagination needed.

```typescript
// BEFORE — fetches every row
const allOrders = await db.orders.findAll();

// AFTER — paginated query
const { page = 1, pageSize = 50 } = req.query;
const orders = await db.orders.findAll({
  limit: Math.min(Number(pageSize), 200),
  offset: (Number(page) - 1) * Math.min(Number(pageSize), 200),
  order: [['createdAt', 'DESC']],
});
```

**Fix:** Mandatory `LIMIT`+`OFFSET` or cursor-based pagination. Enforce max page size at API layer. Use streaming for exports.

---

### Improper Connection Management

**Detection:** `new Connection(...)`, `createClient()`, or `connect()` inside a request handler. Connection opened and closed in the same function is not pooling.

```typescript
// BEFORE — new connection per call
async function getUser(id: string) {
  const client = new Client(dbConfig);
  await client.connect();
  const result = await client.query('SELECT * FROM users WHERE id = $1', [id]);
  await client.end();
  return result.rows[0];
}

// AFTER — shared pool at module scope
import { Pool } from 'pg';
const pool = new Pool(dbConfig);

async function getUser(id: string) {
  const result = await pool.query('SELECT * FROM users WHERE id = $1', [id]);
  return result.rows[0];
}
```

**Fix:** Initialize pool at startup. Inject via constructor or module singleton. Tune pool size to DB `max_connections`.

---

## Category 2: I/O Anti-Patterns

### Chatty I/O

**Detection:** `fetch`, `axios.get`, `redisClient.get`, or `fs.write` inside a loop when bulk APIs exist. Redis `GET` in a loop should be `MGET`.

```typescript
// BEFORE — one request per item
for (const userId of userIds) {
  const profile = await fetch(`/api/profiles/${userId}`).then(r => r.json());
  profiles.push(profile);
}

// AFTER — single batch request
const profiles = await fetch('/api/profiles/batch', {
  method: 'POST',
  body: JSON.stringify({ ids: userIds }),
}).then(r => r.json());
```

**Fix:** Use bulk/batch APIs. Buffer writes and flush periodically. Redis: `MGET`/`MSET` or pipelines.

---

### Synchronous I/O in Hot Path

**Detection:**
- Node.js: `Sync` suffix (`readFileSync`, `writeFileSync`, `execSync`)
- Python async: synchronous `requests`, `open()`, or DB calls without `await`
- Missing `await` before I/O-returning calls

```typescript
// BEFORE — blocking read on every request
app.get('/config', (req, res) => {
  const config = fs.readFileSync('./config.json', 'utf8');
  res.json(JSON.parse(config));
});

// AFTER — async read, cached after first load
let cachedConfig: object | null = null;
app.get('/config', async (req, res) => {
  if (!cachedConfig) {
    const raw = await fs.promises.readFile('./config.json', 'utf8');
    cachedConfig = JSON.parse(raw);
  }
  res.json(cachedConfig);
});
```

**Fix:** Replace sync I/O with async equivalents. Python: `asyncpg`, `httpx`, `aiofiles`. Use `run_in_executor` when async drivers unavailable.

---

## Category 3: Resilience Anti-Patterns

### Retry Storm

**Detection:**
- `while (attempts < MAX)` with `await sleep(FIXED_DELAY)` — no exponential growth
- Missing jitter — `delay * attempt` without `+ Math.random() * baseDelay`
- No circuit breaker state

```typescript
// BEFORE — fixed delay retry, no jitter
async function fetchWithRetry(url: string, maxRetries = 5) {
  for (let i = 0; i < maxRetries; i++) {
    try { return await fetch(url); }
    catch { await sleep(1000); }
  }
  throw new Error('Max retries exceeded');
}

// AFTER — exponential backoff with jitter
async function fetchWithRetry(url: string, maxRetries = 4) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try { return await fetch(url); }
    catch (err) {
      if (attempt === maxRetries - 1) throw err;
      const baseDelay = Math.min(1000 * 2 ** attempt, 30000);
      await sleep(baseDelay + Math.random() * baseDelay);
    }
  }
}
```

**Fix:** Exponential backoff (`baseDelay * 2^attempt`) capped at max. Add jitter. Wrap in circuit breaker.

---

## Category 4: Memory Anti-Patterns

### Memory Leak

**Detection:**
- `addEventListener`/`on(event, handler)` without corresponding removal
- `Map`/object cache with no size limit, TTL, or eviction
- React `useEffect` with subscriptions/timers and no cleanup return

```typescript
// BEFORE — listener never removed
class DataService {
  constructor(private emitter: EventEmitter) {
    this.emitter.on('data', this.handleData.bind(this));
  }
  handleData(data: unknown) { /* ... */ }
}

// AFTER — cleanup on destroy
class DataService {
  private readonly handler: (data: unknown) => void;
  constructor(private emitter: EventEmitter) {
    this.handler = this.handleData.bind(this);
    this.emitter.on('data', this.handler);
  }
  handleData(data: unknown) { /* ... */ }
  destroy() { this.emitter.off('data', this.handler); }
}
```

```typescript
// BEFORE — unbounded cache
const responseCache = new Map<string, Response>();

// AFTER — bounded LRU cache
import LRU from 'lru-cache';
const responseCache = new LRU<string, Response>({ max: 500, ttl: 60_000 });
```

**Fix:** Pair `on`/`addEventListener` with `off`/`removeEventListener` in cleanup. Use bounded caches (LRU, TTL). Audit closures for unintended references.

---

## Category 5: Concurrency Anti-Patterns

### Blocking the Event Loop

**Detection:**
- CPU-heavy algorithms (sorting, hashing, parsing) in route handlers
- `JSON.parse(largeBlob)` in request cycle
- No `worker_threads` or Web Workers for compute-heavy tasks

```typescript
// BEFORE — CPU work blocks all other requests
app.post('/report', (req, res) => {
  const result = generateLargeReport(req.body.data); // blocks for 500ms
  res.json(result);
});

// AFTER — offload to worker thread
import { Worker } from 'worker_threads';
app.post('/report', (req, res) => {
  const worker = new Worker('./report-worker.js', { workerData: req.body.data });
  worker.on('message', (result) => res.json(result));
  worker.on('error', (err) => res.status(500).json({ error: err.message }));
});
```

**Fix:** Move CPU work to `worker_threads` or task queue (BullMQ, Celery). Browsers: Web Workers. Moderate cost: chunk with `setImmediate`.

---

## Category 6: Efficiency Anti-Patterns

### No Caching

**Detection:** Third-party API calls in hot path with no cache check. Expensive aggregation queries without `CACHE_TTL`. Idempotent pure functions called repeatedly with same args.

**Fix:** Cache at the boundary where data enters. In-memory (`lru-cache`) for process-local; Redis/Memcached for shared. Define explicit TTLs. Document invalidation strategy.

---

### String Concatenation in Loops

**Detection:** `+=` on a string variable inside any loop. String accumulation: `let sql = ''; for (...) { sql += ... }`.

```typescript
// BEFORE — O(n^2) allocations
function buildCsv(rows: string[][]): string {
  let csv = '';
  for (const row of rows) { csv += row.join(',') + '\n'; }
  return csv;
}

// AFTER — single join
function buildCsv(rows: string[][]): string {
  return rows.map(row => row.join(',')).join('\n');
}
```

**Fix:** Collect segments in array, `join()` once. Python: `"".join(...)`. SQL: use query builder.

---

### Over-rendering

**Detection:**
- `useEffect(() => ..., [someObject])` where `someObject` is `{}`/`[]` created each render
- Expensive computations in render without `useMemo`
- Callback props not wrapped in `useCallback`

```typescript
// BEFORE — new object reference triggers re-render every time
function ParentComponent({ items }: { items: Item[] }) {
  return <ChildList filters={{ active: true }} items={items} />;
}

// AFTER — stable reference with useMemo
function ParentComponent({ items }: { items: Item[] }) {
  const filters = useMemo(() => ({ active: true }), []);
  const activeItems = useMemo(() => items.filter(i => i.active), [items]);
  return <ChildList filters={filters} items={activeItems} />;
}
```

**Fix:** `useMemo` for expensive computations. `useCallback` for stable callbacks. `React.memo` on pure children. Lift stable values out of render scope.

---

## Review Checklist by PR Type

| PR touches... | Check for... |
|---------------|-------------|
| ORM / database queries | N+1 (query in loop), missing LIMIT, new connection per call |
| HTTP clients / queues | Single call in loop (Chatty I/O), synchronous client in async handler |
| Retry / error handling | Fixed delay, no jitter, no circuit breaker (Retry Storm) |
| Event emitters / caches | No cleanup on removal (Memory Leak), unbounded cache growth |
| Request handlers (Node.js) | Sync API suffix (`readFileSync`), CPU work without worker thread |
| External API calls | No cache layer for slow-changing data |
| String/buffer building | `+=` string in a loop |
| React components | Inline object props, expensive compute outside `useMemo` |

## Cross-References

| Related Skill | Relationship |
|---------------|-------------|
| `anti-patterns-catalog` | Structural anti-patterns that obscure hot paths |
| `review-code-quality-process` | Workflow for performance-focused reviews |
| `detect-code-smells` | Line-level signals that co-occur with performance anti-patterns |
| `design-patterns-behavioral` | Command for queuing, Observer for decoupled events |
| `design-patterns-creational-structural` | Adapter for wrapping slow vendors; Flyweight for shared instances |

## Common Review Mistakes

| Mistake | Correct Approach |
|---------|-----------------|
| Flagging `await` in a loop as always wrong | Only N+1 if awaited call is a DB query or unbatched I/O; sequential async is sometimes intentional |
| Requiring caching everywhere | Caching adds invalidation complexity; only mandate for proven expensive+stable data |
| Treating all string concat as O(n^2) | Modern JS engines optimize small, fixed-iteration cases; flag only unbounded loops |
| Blocking event loop vs. slow async path | Slow `await` does not block the event loop — only synchronous CPU work does |
| Demanding memoization for all components | `React.memo` has overhead; apply only when profiling confirms unnecessary re-renders |
