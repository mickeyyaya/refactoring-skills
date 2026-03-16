---
name: concurrency-patterns
description: Use when reviewing code for concurrency correctness — covers Race Conditions, Deadlocks, Thread Safety, Immutable Data, Producer-Consumer, Actor Model, Thread Pool, Async/Await pitfalls, Read-Write Locks, and Compare-and-Swap with red flags and fix strategies across TypeScript, Java, Go, and Python
---

# Concurrency Patterns for Code Review

## Overview

Concurrency bugs are among the hardest to reproduce and debug: they appear non-deterministically, are often invisible in unit tests, and can cause data corruption in production. Use this guide during code review to catch concurrency hazards before they ship. Each pattern includes specific red flags to spot in a PR diff.

## When to Use

- Reviewing code that accesses shared state from multiple threads or coroutines
- Reviewing async/await code for hidden sequential bottlenecks or error-swallowing
- Evaluating background task queues, worker pools, or message-passing systems
- Any code touching databases, caches, or files from concurrent request handlers

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Race Conditions | Multiple threads read-modify-write shared state | Unsynchronized `count++`, check-then-act without lock |
| Deadlocks | Circular wait on two or more locks | Nested lock acquisition in inconsistent order |
| Thread Safety | Ensuring shared resources are safe to use concurrently | Mutable fields accessed without synchronization |
| Immutable Data | Eliminate races by sharing only read-only values | Passing mutable objects across thread boundaries |
| Producer-Consumer | Decouple work creation from work execution via queue | Unbounded queue, missing backpressure |
| Actor Model | Isolated state, message-only communication | Shared mutable state between actors, blocking in actor |
| Thread Pool | Reuse threads for tasks instead of creating per-request | Thread-per-request at scale, pool exhaustion |
| Async/Await Pitfalls | Common mistakes in async code | Fire-and-forget without error handler, blocking in async |
| Read-Write Locks | Multiple readers OR single writer | Write-heavy workload using `RWLock` (more overhead than mutex) |
| Compare-and-Swap | Lock-free atomic update via CAS loop | ABA problem, spin loop without backoff |

---

## Patterns in Detail

### 1. Race Conditions

**Intent:** Prevent multiple threads from interleaving reads and writes on shared mutable state in ways that produce incorrect results.

**Code Review Red Flags:**
- Unsynchronized increment/decrement: `count++` is read-modify-write — three operations, not one
- Check-then-act without holding a lock: `if (!map.containsKey(k)) { map.put(k, v); }`
- Lazy initialization without synchronization: `if (instance == null) instance = new Foo()`
- Multiple fields updated separately when they should be updated atomically

**TypeScript — Before/After:**
```typescript
// BEFORE — read-modify-write is not atomic across workers
let activeConnections = 0;
function onConnect() { activeConnections++; }

// AFTER — Atomics on SharedArrayBuffer is safe across workers
const counter = new Int32Array(new SharedArrayBuffer(4));
function onConnect() { Atomics.add(counter, 0, 1); }
```

**Java — After:**
```java
private final AtomicInteger count = new AtomicInteger(0);
public void increment() { count.incrementAndGet(); }
```

**Go — After (`go -race` catches the before version):**
```go
var count atomic.Int64
func increment() { count.Add(1) }
```

---

### 2. Deadlocks

**Intent:** Prevent circular wait — Thread A holds Lock 1 and waits for Lock 2; Thread B holds Lock 2 and waits for Lock 1.

**Code Review Red Flags:**
- Nested lock acquisition in different orders across two functions
- A lock held while performing I/O, network calls, or DB queries (long hold time increases contention and risk)
- `synchronized` blocks or `lock()` calls inside callbacks that may already hold a lock
- Missing `finally` or `defer` to release locks on exceptions

**Java — Before/After (inconsistent vs. canonical lock order):**
```java
// BEFORE — Thread A locks `from` first, Thread B may lock `to` first → deadlock
void transfer(Account from, Account to, int amount) {
  synchronized (from) { synchronized (to) { /* race */ } }
}

// AFTER — always lock in consistent order (e.g., by ID)
void transfer(Account from, Account to, int amount) {
  Account first = from.id < to.id ? from : to;
  Account second = from.id < to.id ? to : from;
  synchronized (first) { synchronized (second) {
    from.balance -= amount; to.balance += amount;
  }}
}
```

**Fix Strategy:** Establish a global lock ordering and always acquire locks in that order. Prefer `tryLock` with timeout over indefinite `lock`. Move I/O outside of lock scope.

---

### 3. Thread Safety

**Intent:** Ensure every access to a shared resource is either atomic, synchronized, or uses a thread-safe data structure.

**Code Review Red Flags:**
- `HashMap` used from multiple threads — use `ConcurrentHashMap` (Java) or a mutex-guarded map
- `ArrayList` / `[]T` mutated from multiple goroutines without a lock
- Instance variables of a service/singleton written during requests without synchronization
- `static` mutable fields in Java (class-level state shared by all threads)

**Java — Before/After:**
```java
// BEFORE — HashMap is not thread-safe; check-then-act is a race
private Map<String, User> cache = new HashMap<>();
public User getUser(String id) {
  if (!cache.containsKey(id)) cache.put(id, loadFromDB(id));  // race!
  return cache.get(id);
}

// AFTER — computeIfAbsent is atomic
private final ConcurrentHashMap<String, User> cache = new ConcurrentHashMap<>();
public User getUser(String id) { return cache.computeIfAbsent(id, this::loadFromDB); }
```

**Python — After:**
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

**Intent:** Eliminate race conditions by design — if no thread can mutate the value, no synchronization is needed.

**Code Review Red Flags:**
- Passing mutable collections or objects between threads without copying
- `setX()` / `setY()` mutators on objects shared across goroutines or thread pools
- Config or state objects that are built once but expose mutation methods
- Java classes missing `final` on fields that should never change after construction

**TypeScript — Before/After:**
```typescript
// BEFORE — mutable config shared with workers; mutations cause races
const config = { maxRetries: 3, timeout: 5000 };
workerPool.start(config);
config.timeout = 10000;  // danger: workers may be reading this

// AFTER — freeze creates a read-only snapshot
const config = Object.freeze({ maxRetries: 3, timeout: 5000 } as const);
workerPool.start(config);
```

**Java — After (record: all fields `final`, no setters):**
```java
record Config(int maxRetries, int timeoutMs) {}
```

**Go — After (pass by value; worker owns its own copy):**
```go
type Config struct { MaxRetries int; TimeoutMs int }
func startWorker(cfg Config) { /* cfg is a copy */ }
```

Cross-reference: `refactor-functional-patterns` — Immutability section for array/object immutability patterns in TypeScript and Python.

---

### 5. Producer-Consumer

**Intent:** Decouple the rate of work production from work consumption using a bounded queue, preventing either side from overwhelming the other.

**Code Review Red Flags:**
- Unbounded queue (`new LinkedBlockingQueue<>()` with no capacity) — memory exhaustion under load
- No backpressure: producer blocks or drops silently when consumer is slow
- Consumer catching and swallowing exceptions — tasks silently lost
- Queue depth not monitored — no visibility into buildup

**Go — Before (unbounded channel):**
```go
tasks := make(chan Task)  // unbounded — producer never blocks, OOM risk
```

**Go — After (bounded channel with backpressure):**
```go
const maxQueue = 1000
tasks := make(chan Task, maxQueue)

func produce(t Task) error {
  select {
  case tasks <- t:
    return nil
  default:
    return fmt.Errorf("queue full: applying backpressure to caller")
  }
}
```

**Java — After:**
```java
BlockingQueue<Task> queue = new LinkedBlockingQueue<>(1000);  // bounded
// producer — reject rather than silently drop
if (!queue.offer(task, 100, TimeUnit.MILLISECONDS))
    throw new RejectedExecutionException("Queue full");
// consumer
Task t = queue.poll(1, TimeUnit.SECONDS);
if (t != null) process(t);
```

---

### 6. Actor Model

**Intent:** Each actor owns its state exclusively; actors communicate only by sending messages, eliminating shared mutable state.

**Code Review Red Flags:**
- Actors accessing a shared mutable object directly (bypassing message passing)
- Blocking calls (I/O, `Thread.sleep`, heavy computation) inside an actor's message handler — starves other actors on the same dispatcher
- Unbounded mailbox (same risk as unbounded producer-consumer queue)
- Missing `become` / state transitions — actors that silently handle messages in wrong states

**TypeScript — After (actor: private state accessed only through message dispatch):**
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

**Python — After (asyncio queue as mailbox):**
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

**Intent:** Reuse a fixed set of threads for many tasks rather than creating a new thread per task, capping resource usage.

**Code Review Red Flags:**
- `new Thread(task).start()` inside a request handler — thread-per-request, unbounded thread creation
- `Executors.newCachedThreadPool()` under bursty load — creates unlimited threads
- Thread pool size hard-coded without justification (should depend on CPU count or I/O ratio)
- Submitting tasks to a pool that may itself block waiting for another pool task (pool starvation deadlock)
- No shutdown hook — threads keep the JVM alive after main exits

**Java — Before/After:**
```java
// BEFORE — one OS thread per request, unbounded
new Thread(() -> handleRequest(req)).start();

// AFTER — fixed pool; track future for error handling and timeout
ExecutorService pool = Executors.newFixedThreadPool(
    Runtime.getRuntime().availableProcessors() * 2  // CPU-bound: 1x; IO-bound: 2x+
);
Future<Result> future = pool.submit(() -> handleRequest(req));
```

**Go — After:**
```go
func newWorkerPool(workers int, jobs <-chan Job) {
    for range workers {
        go func() { for job := range jobs { process(job) } }()
    }
}
```

---

### 8. Async/Await Pitfalls

**Intent:** Avoid the class of bugs unique to async code: unobserved errors, blocking event loops, and missing cancellation.

**Code Review Red Flags:**
- Fire-and-forget without error handler: `somePromise()` (TypeScript) or `asyncio.create_task(coro())` with no `.add_done_callback`
- `async void` in C# / `async` function called without `await` — exceptions are swallowed
- `await` inside a `forEach` loop — runs iterations sequentially instead of in parallel
- Calling synchronous blocking I/O (`fs.readFileSync`, `time.sleep`) inside an async function — blocks the event loop
- Missing cancellation token / `AbortSignal` — long-running tasks that cannot be stopped

**TypeScript — Before/After (sequential vs. parallel):**
```typescript
// BEFORE — sequential: each await blocks the next fetch
async function loadAll(ids: string[]): Promise<User[]> {
  const users: User[] = [];
  for (const id of ids) { users.push(await fetchUser(id)); }
  return users;
}

// AFTER — all fetches in parallel
async function loadAll(ids: readonly string[]): Promise<readonly User[]> {
  return Promise.all(ids.map(id => fetchUser(id)));
}

// Fire-and-forget — WRONG (errors swallowed) / CORRECT (catch attached)
cleanupExpiredSessions();                                         // wrong
cleanupExpiredSessions().catch(err => logger.error('Cleanup', { err })); // correct
```

**Python — After:**
```python
async def load_all(ids: list[str]) -> list[User]:
    return await asyncio.gather(*[fetch_user(uid) for uid in ids])
```

---

### 9. Read-Write Locks

**Intent:** Allow multiple concurrent readers OR a single exclusive writer — higher throughput than a plain mutex for read-heavy workloads.

**Code Review Red Flags:**
- Using `RWLock` in a write-heavy workload — the bookkeeping overhead exceeds the gain; use a plain `Mutex`
- Holding a write lock while performing I/O (same as holding a regular lock during I/O)
- Upgrading from read lock to write lock without releasing the read lock first — deadlock risk
- `RLock` / `RUnlock` mismatches — missing unlock on error paths

**Go — After (defer ensures unlock on panic):**
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

**Java — After:**
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

**Intent:** Update a value atomically without a lock: read current value, compute new value, write only if current value has not changed since the read.

**Code Review Red Flags:**
- ABA problem: value changes A→B→A between CAS read and write; the CAS succeeds but the state has changed meaningfully (use stamped references or versioned counters)
- Unbounded spin loop without backoff — wastes CPU and can livelock under high contention
- Using CAS for multi-field updates — CAS is single-variable; multi-field updates require a lock or a versioned snapshot reference

**Java — After (AtomicReference CAS loop):**
```java
AtomicReference<State> stateRef = new AtomicReference<>(initialState);
void updateState(UnaryOperator<State> transform) {
  State current, next;
  do {
    current = stateRef.get();
    next = transform.apply(current);
  } while (!stateRef.compareAndSet(current, next));  // retry if state changed
}
```

**Go — After (yield between retries to prevent livelock):**
```go
var value atomic.Int64
func increment() {
    for {
        old := value.Load()
        if value.CompareAndSwap(old, old+1) { return }
        runtime.Gosched()  // backoff
    }
}
```

---

## Concurrency Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Double-checked locking** | `if (x == null) { synchronized { if (x == null) x = new X(); } }` — broken without `volatile` in Java, broken in many languages | Use `volatile` + double-check (Java 5+) or prefer `once.Do` (Go) / `static` initializers |
| **Lock held during I/O** | Holding a mutex while reading from disk or network — blocks all other threads for the full I/O latency | Load data outside the lock; swap the reference under a brief lock |
| **Thread-per-connection at scale** | Creating one OS thread per client connection — exhausted at ~10k connections | Use non-blocking I/O with a thread pool or async event loop |
| **Swallowed InterruptedException** | `catch (InterruptedException e) { /* ignore */ }` — breaks cooperative cancellation | Re-interrupt the thread: `Thread.currentThread().interrupt()` or rethrow |
| **`Thread.sleep()` for synchronization** | Using sleep to wait for another thread to complete a task | Use `CountDownLatch`, `CompletableFuture`, `WaitGroup`, or a channel |
| **Async void / fire-and-forget** | Launching an async task with no error handler — exceptions silently swallowed | Always attach `.catch()` / `.add_done_callback()` / store the `Future` |
| **Closure over mutable loop variable** | Lambda captures `i` in a loop — all closures share the same variable | Capture a copy: `final int copy = i;` or use stream/forEach directly |

**Double-checked locking — Java fix:**
```java
// WRONG — without volatile, JIT may publish partially-constructed object
private static Singleton instance;

// CORRECT — volatile ensures full visibility before reference is published
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

- `refactor-functional-patterns` — Immutability section: use immutable data structures to eliminate the need for synchronization entirely
- `review-code-quality-process` — Error handling checklist: async errors and interrupted exceptions are a subset of the broader error-handling review
- `review-solid-clean-code` — Single Responsibility Principle: separating I/O from computation makes concurrency boundaries explicit
- `detect-code-smells` — "Shotgun Surgery" and "Feature Envy" smells often indicate state that should be consolidated behind a single owner (actor or mutex)
