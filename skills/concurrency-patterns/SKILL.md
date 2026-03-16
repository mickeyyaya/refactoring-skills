---
name: concurrency-patterns
description: Use when reviewing code for concurrency correctness — covers Race Conditions, Deadlocks, Thread Safety, Immutable Data, Producer-Consumer, Actor Model, Thread Pool, Async/Await pitfalls, Read-Write Locks, and Compare-and-Swap with red flags and fix strategies across TypeScript, Java, Go, and Python
---

# Concurrency Patterns for Code Review

## Overview

Concurrency bugs are among the hardest to reproduce: they appear non-deterministically, are invisible in unit tests, and can cause data corruption in production. Use this guide during code review to catch concurrency hazards before they ship.

## When to Use

- Reviewing code that accesses shared state from multiple threads or coroutines
- Reviewing async/await code for hidden bottlenecks or error-swallowing
- Evaluating background task queues, worker pools, or message-passing systems
- Code touching databases, caches, or files from concurrent request handlers

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Race Conditions | Multiple threads read-modify-write shared state | Unsynchronized `count++`, check-then-act without lock |
| Deadlocks | Circular wait on two or more locks | Nested lock acquisition in inconsistent order |
| Thread Safety | Ensuring shared resources are safe to use concurrently | Mutable fields accessed without synchronization |
| Immutable Data | Eliminate races by sharing only read-only values | Passing mutable objects across thread boundaries |
| Producer-Consumer | Decouple work creation from execution via queue | Unbounded queue, missing backpressure |
| Actor Model | Isolated state, message-only communication | Shared mutable state between actors, blocking in actor |
| Thread Pool | Reuse threads instead of creating per-request | Thread-per-request at scale, pool exhaustion |
| Async/Await Pitfalls | Common mistakes in async code | Fire-and-forget without error handler, blocking in async |
| Read-Write Locks | Multiple readers OR single writer | Write-heavy workload using `RWLock` (more overhead than mutex) |
| Compare-and-Swap | Lock-free atomic update via CAS loop | ABA problem, spin loop without backoff |

---

## Patterns in Detail

### 1. Race Conditions

**Red Flags:**
- Unsynchronized `count++` — read-modify-write is three operations, not one
- Check-then-act without lock: `if (!map.containsKey(k)) { map.put(k, v); }`
- Lazy init without synchronization: `if (instance == null) instance = new Foo()`
- Multiple fields updated separately when they should be atomic

**TypeScript:**
```typescript
// BEFORE — read-modify-write is not atomic across workers
let activeConnections = 0;
function onConnect() { activeConnections++; }

// AFTER — Atomics on SharedArrayBuffer
const counter = new Int32Array(new SharedArrayBuffer(4));
function onConnect() { Atomics.add(counter, 0, 1); }
```

**Java:** `private final AtomicInteger count = new AtomicInteger(0);`
**Go:** `var count atomic.Int64` / `count.Add(1)`

---

### 2. Deadlocks

**Red Flags:**
- Nested lock acquisition in different orders across two functions
- Lock held during I/O, network, or DB calls (long hold time = high contention)
- `synchronized`/`lock()` inside callbacks that may already hold a lock
- Missing `finally`/`defer` to release locks on exceptions

**Java:**
```java
// BEFORE — Thread A locks `from` first, Thread B may lock `to` first
void transfer(Account from, Account to, int amount) {
  synchronized (from) { synchronized (to) { /* race */ } }
}

// AFTER — always lock in consistent order (by ID)
void transfer(Account from, Account to, int amount) {
  Account first = from.id < to.id ? from : to;
  Account second = from.id < to.id ? to : from;
  synchronized (first) { synchronized (second) {
    from.balance -= amount; to.balance += amount;
  }}
}
```

**Fix:** Global lock ordering. Prefer `tryLock` with timeout. Move I/O outside lock scope.

---

### 3. Thread Safety

**Red Flags:**
- `HashMap` from multiple threads — use `ConcurrentHashMap` or mutex-guarded map
- `ArrayList`/`[]T` mutated from multiple goroutines without lock
- Service/singleton instance variables written during requests without synchronization
- `static` mutable fields in Java

**Java:**
```java
// BEFORE — HashMap is not thread-safe; check-then-act is a race
private Map<String, User> cache = new HashMap<>();
public User getUser(String id) {
  if (!cache.containsKey(id)) cache.put(id, loadFromDB(id));
  return cache.get(id);
}

// AFTER — computeIfAbsent is atomic
private final ConcurrentHashMap<String, User> cache = new ConcurrentHashMap<>();
public User getUser(String id) { return cache.computeIfAbsent(id, this::loadFromDB); }
```

**Python:**
```python
class UserCache:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cache: dict[str, User] = {}
    def get_user(self, user_id: str) -> User:
        with self._lock:
            if user_id not in self._cache:
                self._cache[user_id] = load_from_db(user_id)
            return self._cache[user_id]
```

---

### 4. Immutable Data

**Red Flags:**
- Passing mutable collections between threads without copying
- `setX()`/`setY()` mutators on objects shared across goroutines or thread pools
- Config objects built once but exposing mutation methods
- Java classes missing `final` on fields that should never change

**TypeScript:**
```typescript
// BEFORE — mutable config shared with workers; mutations cause races
const config = { maxRetries: 3, timeout: 5000 };
workerPool.start(config);
config.timeout = 10000;  // workers may be reading this

// AFTER — freeze creates a read-only snapshot
const config = Object.freeze({ maxRetries: 3, timeout: 5000 } as const);
workerPool.start(config);
```

**Java:** `record Config(int maxRetries, int timeoutMs) {}` (all fields final, no setters)
**Go:** `func startWorker(cfg Config) { /* cfg is a copy — pass by value */ }`

Cross-reference: `refactor-functional-patterns` — Immutability section for array/object patterns.

---

### 5. Producer-Consumer

**Red Flags:**
- Unbounded queue (`new LinkedBlockingQueue<>()` with no capacity) — OOM under load
- No backpressure: producer blocks or drops silently when consumer is slow
- Consumer swallowing exceptions — tasks silently lost
- Queue depth not monitored

**Go:**
```go
// BEFORE — unbounded channel, OOM risk
tasks := make(chan Task)

// AFTER — bounded channel with backpressure
const maxQueue = 1000
tasks := make(chan Task, maxQueue)
func produce(t Task) error {
  select {
  case tasks <- t: return nil
  default: return fmt.Errorf("queue full: applying backpressure")
  }
}
```

**Java:**
```java
BlockingQueue<Task> queue = new LinkedBlockingQueue<>(1000);
if (!queue.offer(task, 100, TimeUnit.MILLISECONDS))
    throw new RejectedExecutionException("Queue full");
```

---

### 6. Actor Model

**Red Flags:**
- Actors accessing shared mutable objects directly (bypassing messages)
- Blocking calls inside actor message handler — starves other actors
- Unbounded mailbox (same risk as unbounded queue)
- Missing state transitions — actors handling messages in wrong states

**TypeScript:**
```typescript
type Msg = { type: 'increment' } | { type: 'get'; reply: (n: number) => void };
class CounterActor {
  private count = 0;
  private mailbox: Msg[] = [];
  private running = false;
  send(msg: Msg) { this.mailbox.push(msg); if (!this.running) this.drain(); }
  private drain() {
    this.running = true;
    while (this.mailbox.length) {
      const msg = this.mailbox.shift()!;
      if (msg.type === 'increment') this.count++; else msg.reply(this.count);
    }
    this.running = false;
  }
}
```

**Python (asyncio queue as mailbox):**
```python
class CounterActor:
    def __init__(self) -> None:
        self._count = 0; self._queue: asyncio.Queue[tuple] = asyncio.Queue()
    async def run(self) -> None:
        while True:
            msg, fut = await self._queue.get()
            if msg == 'increment': self._count += 1; fut.set_result(None)
            elif msg == 'get': fut.set_result(self._count)
```

---

### 7. Thread Pool / Worker Pool

**Red Flags:**
- `new Thread(task).start()` in request handler — unbounded thread creation
- `Executors.newCachedThreadPool()` under bursty load — unlimited threads
- Pool size hard-coded without justification (should depend on CPU count or I/O ratio)
- Tasks submitted to a pool that block waiting for another pool task (starvation deadlock)
- No shutdown hook — threads keep JVM alive after main exits

**Java:**
```java
// BEFORE — one OS thread per request, unbounded
new Thread(() -> handleRequest(req)).start();

// AFTER — fixed pool with sized based on workload
ExecutorService pool = Executors.newFixedThreadPool(
    Runtime.getRuntime().availableProcessors() * 2  // CPU-bound: 1x; IO-bound: 2x+
);
Future<Result> future = pool.submit(() -> handleRequest(req));
```

**Go:**
```go
func newWorkerPool(workers int, jobs <-chan Job) {
    for range workers {
        go func() { for job := range jobs { process(job) } }()
    }
}
```

---

### 8. Async/Await Pitfalls

**Red Flags:**
- Fire-and-forget: `somePromise()` or `asyncio.create_task(coro())` with no error callback
- `async void` (C#) / `async` called without `await` — exceptions swallowed
- `await` inside `forEach` — sequential instead of parallel
- Sync blocking I/O (`fs.readFileSync`, `time.sleep`) inside async function
- Missing `AbortSignal` — long-running tasks that cannot be stopped

**TypeScript:**
```typescript
// BEFORE — sequential: each await blocks the next
async function loadAll(ids: string[]): Promise<User[]> {
  const users: User[] = [];
  for (const id of ids) { users.push(await fetchUser(id)); }
  return users;
}

// AFTER — parallel
async function loadAll(ids: readonly string[]): Promise<readonly User[]> {
  return Promise.all(ids.map(id => fetchUser(id)));
}

// Fire-and-forget — WRONG vs. CORRECT
cleanupExpiredSessions();                                         // wrong
cleanupExpiredSessions().catch(err => logger.error('Cleanup', { err })); // correct
```

**Python:**
```python
async def load_all(ids: list[str]) -> list[User]:
    return await asyncio.gather(*[fetch_user(uid) for uid in ids])
```

---

### 9. Read-Write Locks

**Red Flags:**
- `RWLock` in write-heavy workload — overhead exceeds gain; use plain `Mutex`
- Write lock held during I/O
- Upgrading read lock to write lock without release — deadlock risk
- `RLock`/`RUnlock` mismatches on error paths

**Go:**
```go
type SafeMap struct { mu sync.RWMutex; m map[string]string }
func (s *SafeMap) Get(key string) (string, bool) {
    s.mu.RLock(); defer s.mu.RUnlock()
    return s.m[key]
}
func (s *SafeMap) Set(key, value string) {
    s.mu.Lock(); defer s.mu.Unlock()
    s.m[key] = value
}
```

**Java:**
```java
private final ReadWriteLock rwLock = new ReentrantReadWriteLock();
public String get(String key) {
    rwLock.readLock().lock();
    try { return map.get(key); } finally { rwLock.readLock().unlock(); }
}
public void put(String key, String value) {
    rwLock.writeLock().lock();
    try { map.put(key, value); } finally { rwLock.writeLock().unlock(); }
}
```

---

### 10. Compare-and-Swap (CAS)

**Red Flags:**
- ABA problem: value changes A->B->A; CAS succeeds but state changed meaningfully (use stamped references)
- Unbounded spin loop without backoff — CPU waste, livelock risk
- CAS for multi-field updates — CAS is single-variable; multi-field needs lock or versioned snapshot

**Java:**
```java
AtomicReference<State> stateRef = new AtomicReference<>(initialState);
void updateState(UnaryOperator<State> transform) {
  State current, next;
  do {
    current = stateRef.get();
    next = transform.apply(current);
  } while (!stateRef.compareAndSet(current, next));
}
```

**Go (yield between retries to prevent livelock):**
```go
var value atomic.Int64
func increment() {
    for {
        old := value.Load()
        if value.CompareAndSwap(old, old+1) { return }
        runtime.Gosched()
    }
}
```

---

## Concurrency Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Double-checked locking** | Broken without `volatile` in Java | Use `volatile` + double-check (Java 5+), `once.Do` (Go), or `static` initializers |
| **Lock held during I/O** | Blocks all threads for full I/O latency | Load data outside lock; swap reference under brief lock |
| **Thread-per-connection** | Exhausted at ~10k connections | Non-blocking I/O with thread pool or async event loop |
| **Swallowed InterruptedException** | Breaks cooperative cancellation | Re-interrupt: `Thread.currentThread().interrupt()` |
| **`Thread.sleep()` for sync** | Sleeping to wait for another thread | Use `CountDownLatch`, `CompletableFuture`, `WaitGroup`, or channel |
| **Async void / fire-and-forget** | Exceptions silently swallowed | Always attach `.catch()` / `.add_done_callback()` / store `Future` |
| **Closure over mutable loop var** | All closures share same variable | Capture a copy: `final int copy = i;` |

**Double-checked locking — Java fix:**
```java
// WRONG — without volatile, JIT may publish partially-constructed object
private static Singleton instance;

// CORRECT — volatile ensures visibility before reference published
private static volatile Singleton instance;
public static Singleton getInstance() {
  if (instance == null) { synchronized (Singleton.class) {
    if (instance == null) instance = new Singleton();
  }}
  return instance;
}
```

---

## Cross-References

- `refactor-functional-patterns` — Immutability: use immutable data to eliminate synchronization
- `review-code-quality-process` — Async errors and interrupted exceptions in broader error-handling review
- `review-solid-clean-code` — SRP: separating I/O from computation makes concurrency boundaries explicit
- `detect-code-smells` — "Shotgun Surgery"/"Feature Envy" indicate state that should be behind a single owner
