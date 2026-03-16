---
name: performance-anti-patterns
description: Use when reviewing a PR for performance regressions, when a service is slow under load, when database query times are spiking, or when CPU or memory usage is growing unexpectedly
---

# Performance Anti-Patterns for Code Review

## Overview

Performance anti-patterns are recurring implementation mistakes that degrade throughput, latency, or resource efficiency. Unlike correctness bugs, they often go undetected in development and surface only under production load. This catalog focuses on signals a reviewer can spot in a PR without running the code.

Use this alongside `anti-patterns-catalog` (structural problems) and `review-code-quality-process` (review workflow). Structural anti-patterns like God Object and Spaghetti Code frequently co-occur with the patterns below because tangled code hides the hot path.

## When to Use

- A PR touches database queries, HTTP clients, or any I/O layer
- A service's p95 latency or memory usage has increased without obvious cause
- Load testing reveals performance does not scale linearly with load
- A PR introduces new loops, recursion, or collection transformations
- A PR modifies caching logic or connection management

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

- **Description**: A query is executed once to fetch N parent records, then once more per parent to fetch related children — producing N+1 total queries.
- **Symptoms**:
  - A loop body contains a function that queries the database
  - ORM calls like `findById`, `getRelated`, or `load` appear inside `forEach`, `map`, or `for...of`
  - Query count in logs scales linearly with list size (10 items → 11 queries, 100 items → 101 queries)
- **Detection in Code Review**:
  - Look for any database/ORM call nested inside a loop or array transform
  - Check if relationships are loaded lazily by default in the ORM — lazy loading is N+1 by default
  - In Python/SQLAlchemy: look for `session.query` inside a loop over results
  - In TypeScript/Prisma or TypeORM: look for `findOne` / `findById` inside `Promise.all(items.map(...))`

```typescript
// BEFORE — N+1: one query per user
const users = await db.users.findAll();
for (const user of users) {
  user.orders = await db.orders.findAll({ where: { userId: user.id } }); // query per iteration
}

// AFTER — single JOIN query
const users = await db.users.findAll({
  include: [{ model: db.orders }],
});
```

- **Fix Strategy**: Use JOIN-based eager loading, `include`/`joinedload` in ORMs, or load children in a single batched query keyed by parent IDs. In Python/SQLAlchemy use `joinedload(User.orders)`. For REST/GraphQL data sources, use DataLoader-style batching.

---

### Unbounded Data Fetching

- **Description**: A query or API call retrieves all records with no upper bound, causing memory and latency to grow linearly with data volume.
- **Symptoms**:
  - `SELECT *` or ORM `findAll()` without a `LIMIT` clause
  - API calls with no pagination parameters
  - Response payload size grows unboundedly as data accumulates
- **Detection in Code Review**:
  - Search for `findAll`, `SELECT *`, or `getAll` without accompanying `LIMIT`, `take`, or `pageSize`
  - Check if the result is immediately serialized to JSON for an HTTP response — a good signal that pagination is needed
  - Look for `.length` checks after fetching all records — this pattern suggests filtering should happen in the query

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

- **Fix Strategy**: Add mandatory `LIMIT` and `OFFSET` (or cursor-based pagination) to all list queries. Define a maximum page size and enforce it at the API layer. Use streaming for export/batch operations.

---

### Improper Connection Management

- **Description**: Database connections are created per request or per function call rather than acquired from a connection pool.
- **Symptoms**:
  - `new Connection(...)`, `createClient()`, or `connect()` called inside a request handler or utility function
  - Connection object is not reused across requests
  - Connection count in the database spikes under load and exceeds the server's limit
- **Detection in Code Review**:
  - Look for database client instantiation at function scope rather than module scope or DI container
  - Check if the connection is closed inside the same function it was opened — this is not pooling
  - In Python: `psycopg2.connect()` inside a route handler; in Node.js: `new Pool()` per request

```typescript
// BEFORE — new connection per call
async function getUser(id: string) {
  const client = new Client(dbConfig); // connection per call
  await client.connect();
  const result = await client.query('SELECT * FROM users WHERE id = $1', [id]);
  await client.end();
  return result.rows[0];
}

// AFTER — shared pool at module scope
import { Pool } from 'pg';
const pool = new Pool(dbConfig); // initialized once

async function getUser(id: string) {
  const result = await pool.query('SELECT * FROM users WHERE id = $1', [id]);
  return result.rows[0];
}
```

- **Fix Strategy**: Initialize a connection pool at application startup. Inject it via constructor or module-level singleton. Ensure pool size is tuned to the database server's `max_connections`.

---

## Category 2: I/O Anti-Patterns

### Chatty I/O

- **Description**: Performing many small I/O operations where one larger operation would suffice. Common with file systems, HTTP APIs, and message queues.
- **Symptoms**:
  - Sending one HTTP request per item in a list when a bulk API exists
  - Writing to a file or queue one record at a time inside a loop
  - Making individual cache `GET` calls per item when `MGET` is available
- **Detection in Code Review**:
  - Look for `fetch`, `axios.get`, `redisClient.get`, or `fs.write` inside a loop
  - Check if the target API offers a batch endpoint — if so, single-call usage in a loop is Chatty I/O
  - Look at Redis usage: `GET key` in a loop should be `MGET key1 key2 ...`

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

- **Fix Strategy**: Use bulk/batch APIs when available. Buffer writes and flush periodically. For Redis, replace single-key `GET`/`SET` loops with `MGET`/`MSET` or pipelines.

---

### Synchronous I/O in Hot Path

- **Description**: Blocking I/O (file reads, network calls, synchronous database drivers) executed on the request-handling thread, stalling all concurrent requests.
- **Symptoms**:
  - `fs.readFileSync`, `execSync`, or any synchronous I/O API in a web server handler
  - Missing `await` on a Promise-returning function — the call runs but the result is not awaited, OR the entire function is synchronous when it should be async
  - Python `requests.get()` (synchronous) used inside an `async def` handler without `run_in_executor`
- **Detection in Code Review**:
  - Search for `Sync` suffix in Node.js (e.g., `readFileSync`, `writeFileSync`, `execSync`)
  - In Python async code: look for synchronous `requests`, `open()`, or database calls without `await`
  - Check for missing `await` keywords before I/O-returning calls in TypeScript/JS

```typescript
// BEFORE — blocking read on every request
app.get('/config', (req, res) => {
  const config = fs.readFileSync('./config.json', 'utf8'); // blocks event loop
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

- **Fix Strategy**: Replace all synchronous I/O APIs with their async equivalents. In Python, use `asyncio`-compatible drivers (`asyncpg`, `httpx`, `aiofiles`). Move blocking work to a thread pool via `run_in_executor` when async drivers are unavailable.

---

## Category 3: Resilience Anti-Patterns

### Retry Storm

- **Description**: A client retries failed requests immediately and aggressively, overwhelming a degraded downstream service and preventing its recovery.
- **Symptoms**:
  - Retry loop with fixed delay or no delay
  - No maximum retry count or overly large maximum
  - No jitter: all clients retry at the same time after a delay
  - No circuit breaker: requests continue even when all recent attempts have failed
- **Detection in Code Review**:
  - Look for `while (attempts < MAX)` or `for` retry loops with `await sleep(FIXED_DELAY)`
  - Check for missing jitter — `delay * attempt` without `+ Math.random() * baseDelay`
  - Check for missing circuit breaker state or exponential growth in the delay

```typescript
// BEFORE — fixed delay retry, no jitter
async function fetchWithRetry(url: string, maxRetries = 5) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fetch(url);
    } catch {
      await sleep(1000); // all callers retry at exactly the same time
    }
  }
  throw new Error('Max retries exceeded');
}

// AFTER — exponential backoff with jitter
async function fetchWithRetry(url: string, maxRetries = 4) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fetch(url);
    } catch (err) {
      if (attempt === maxRetries - 1) throw err;
      const baseDelay = Math.min(1000 * 2 ** attempt, 30000);
      const jitter = Math.random() * baseDelay;
      await sleep(baseDelay + jitter);
    }
  }
}
```

- **Fix Strategy**: Implement exponential backoff (`baseDelay * 2^attempt`) capped at a maximum. Add random jitter (`± 50% of delay`) to desynchronize clients. Wrap retries in a circuit breaker that stops retrying after a threshold failure rate.

---

## Category 4: Memory Anti-Patterns

### Memory Leak

- **Description**: Objects are allocated and retain references longer than their useful lifetime, preventing garbage collection and causing heap growth over time.
- **Symptoms**:
  - Event listeners registered in a setup function but never removed
  - A cache or registry that grows without eviction logic
  - Closures in long-lived objects holding references to large outer scope objects
  - Memory usage grows steadily with uptime (not just with load)
- **Detection in Code Review**:
  - Look for `addEventListener`, `on(event, handler)` without a corresponding `removeEventListener` or `off`
  - Look for `Map` or `object` used as a cache with no size limit, TTL, or eviction
  - In React: `useEffect` with subscriptions or timers that have no cleanup return function

```typescript
// BEFORE — listener never removed
class DataService {
  constructor(private emitter: EventEmitter) {
    this.emitter.on('data', this.handleData.bind(this)); // reference never released
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
  destroy() {
    this.emitter.off('data', this.handler); // explicit release
  }
}
```

```typescript
// BEFORE — unbounded cache
const responseCache = new Map<string, Response>();
async function fetchCached(url: string) {
  if (!responseCache.has(url)) {
    responseCache.set(url, await fetch(url).then(r => r.json()));
  }
  return responseCache.get(url);
}

// AFTER — bounded LRU cache (e.g., lru-cache library)
import LRU from 'lru-cache';
const responseCache = new LRU<string, Response>({ max: 500, ttl: 60_000 });
```

- **Fix Strategy**: Always pair `on`/`addEventListener` with `off`/`removeEventListener` in a cleanup method or `useEffect` teardown. Use bounded caches (LRU, TTL-based). Audit closures in long-lived objects for unintended large references.

---

## Category 5: Concurrency Anti-Patterns

### Blocking the Event Loop

- **Description**: CPU-intensive synchronous work runs on Node.js's single-threaded event loop (or the browser's main thread), starving all concurrent I/O and rendering.
- **Symptoms**:
  - Heavy computation (sorting large arrays, parsing, encryption, image processing) in a route handler or component render
  - `JSON.parse` or `JSON.stringify` on very large payloads inline in a request handler
  - Tight loops with no `await` points that run for > ~16ms
- **Detection in Code Review**:
  - Look for CPU-heavy algorithms (sorting, hashing, parsing) directly in route handlers or event callbacks
  - Check payload sizes: `JSON.parse(largeBlob)` inside a request cycle is a red flag
  - Look for absence of `worker_threads` or Web Workers for tasks labeled as "heavy" or "compute"

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

- **Fix Strategy**: Move CPU-bound work to Node.js `worker_threads` or a task queue (BullMQ, Celery). In browsers, use Web Workers. For moderate-cost work, break processing into chunks with `setImmediate` yield points.

---

## Category 6: Efficiency Anti-Patterns

### No Caching

- **Description**: Data that is expensive to compute or fetch and changes infrequently is recomputed or re-fetched on every request.
- **Symptoms**:
  - An external API is called on every page load for data that updates once per hour
  - A complex database aggregation runs per request with no cache TTL
  - `console.log` or profiling reveals the same computation result multiple times per second
- **Detection in Code Review**:
  - Look for third-party API calls in the hot path with no cache check preceding them
  - Check for expensive aggregation queries without a `CACHE_TTL` or Redis prefetch
  - Look for idempotent pure functions called repeatedly with the same arguments in tight loops

- **Fix Strategy**: Introduce a cache layer at the boundary where data enters the system. Use in-memory caches (Map, `lru-cache`) for process-local data. Use Redis or Memcached for data shared across instances. Define explicit TTLs aligned with acceptable staleness. Document the cache invalidation strategy in code comments.

---

### String Concatenation in Loops

- **Description**: Building a string incrementally using `+=` inside a loop. In many runtimes, each concatenation allocates a new string object, producing O(n²) allocations for n iterations.
- **Symptoms**:
  - `result += item` inside a `for` or `while` loop building a large string
  - SQL queries or HTML strings assembled character-by-character or segment-by-segment in a loop
- **Detection in Code Review**:
  - Search for `+=` applied to a string variable inside any loop
  - Look for string accumulation patterns: `let sql = ''; for (...) { sql += ... }`

```typescript
// BEFORE — O(n²) allocations
function buildCsv(rows: string[][]): string {
  let csv = '';
  for (const row of rows) {
    csv += row.join(',') + '\n'; // new string per iteration
  }
  return csv;
}

// AFTER — single join call
function buildCsv(rows: string[][]): string {
  return rows.map(row => row.join(',')).join('\n');
}
```

- **Fix Strategy**: Collect string segments in an array and call `Array.join()` once at the end. In Python, use `"".join(str(item) for item in items)`. For SQL builders, use a query builder library rather than string concatenation.

---

### Over-rendering

- **Description**: UI components re-render more often than their displayed data changes, wasting CPU cycles and causing visible jank.
- **Symptoms**:
  - React components without `React.memo` receive new object/array references on every parent render
  - `useEffect` dependency arrays contain objects or functions created inline — new reference each render
  - Derived state is recomputed inline in render instead of being memoized with `useMemo`
- **Detection in Code Review**:
  - Look for `useEffect(() => ..., [someObject])` where `someObject` is created with `{}` or `[]` in the same render
  - Look for expensive computations (filtering, sorting large arrays) directly in render functions without `useMemo`
  - Check if callback props passed to child components are wrapped in `useCallback`

```typescript
// BEFORE — new array reference triggers re-render every time
function ParentComponent({ items }: { items: Item[] }) {
  return <ChildList filters={{ active: true }} items={items} />; // new object each render
}

// AFTER — stable reference with useMemo
function ParentComponent({ items }: { items: Item[] }) {
  const filters = useMemo(() => ({ active: true }), []);
  const activeItems = useMemo(() => items.filter(i => i.active), [items]);
  return <ChildList filters={filters} items={activeItems} />;
}
```

- **Fix Strategy**: Wrap expensive computations in `useMemo`. Stabilize callback references with `useCallback`. Use `React.memo` on pure child components. Lift stable values out of render scope or to a ref when appropriate.

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
| `anti-patterns-catalog` | Structural anti-patterns (God Object, Spaghetti Code) that obscure hot paths |
| `review-code-quality-process` | Workflow for conducting performance-focused reviews |
| `detect-code-smells` | Line-level signals that co-occur with performance anti-patterns |
| `design-patterns-behavioral` | Command pattern for queuing, Observer for decoupled event handling |
| `design-patterns-creational-structural` | Adapter for wrapping slow vendors; Flyweight for shared instances |

## Common Review Mistakes

| Mistake | Correct Approach |
|---------|-----------------|
| Flagging `await` in a loop as always wrong | Awaiting in a loop is only N+1 if the awaited call is a database query or unbatched I/O; sequential async processing is sometimes intentional |
| Requiring caching everywhere | Caching adds invalidation complexity; only mandate it when the data is proven expensive and stable |
| Treating all string concatenation as O(n²) | Modern JS engines optimize small, fixed-iteration concatenation; flag only loops with unbounded or large iteration counts |
| Blocking the event loop vs. slow async path | A slow `await` does not block the event loop — only synchronous CPU work does |
| Demanding memoization for all React components | `React.memo` has overhead; apply it only when profiling confirms unnecessary re-renders |
