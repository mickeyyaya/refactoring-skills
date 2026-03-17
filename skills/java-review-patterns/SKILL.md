---
name: java-review-patterns
description: Use when reviewing Java code — covers null safety and Optional misuse, Stream API pitfalls, concurrency hazards (synchronized scope, CompletableFuture, ThreadLocal), resource management via try-with-resources, generics and type erasure traps, immutability patterns, and common Java anti-patterns. Load alongside review-accuracy-calibration to ensure findings are well-calibrated before posting comments.
---

# Java Code Review Patterns

## Overview

Java's size and long history create a distinct review challenge: the language has grown from Java 1 to Java 21 without removing legacy APIs, leaving reviewers to distinguish safe modern idioms from outdated patterns still present in production codebases.

Three forces drive Java-specific review mistakes. First, null is pervasive — NullPointerException remains the most common runtime crash, and Optional was introduced in Java 8 to address this but is frequently misused. Second, the Stream API enables elegant functional pipelines but introduces subtle bugs when side effects, infinite sequences, or parallelism are mixed in carelessly. Third, Java's threading model predates structured concurrency, and the `synchronized` keyword is still widely used, often with scope wider than necessary, while newer tools like `CompletableFuture` introduce their own error-swallowing traps.

Load this skill when reviewing any Java PR that touches service logic, data access, background tasks, or concurrent processing. Cross-reference `review-accuracy-calibration` before posting — Java has moderate false positive risk in the generics and concurrency sections, where correct-looking code can be intentionally chosen over the more idiomatic form.

## Quick Reference

| Review Dimension | Severity | Primary Red Flag |
|---|---|---|
| Optional.get() without isPresent | HIGH | `opt.get()` without guard — throws NoSuchElementException |
| Optional as field or parameter | MEDIUM | `Optional<T>` stored in a struct or passed as method arg |
| Null returned where Optional expected | MEDIUM | Method declared to return Optional but returns null |
| Side effect in stream pipeline | HIGH | `.forEach(list::add)` or mutation inside `.map()` |
| Infinite stream without limit | HIGH | `Stream.iterate(...)` with no `.limit()` or `.takeWhile()` |
| Heavy work in parallel stream | MEDIUM | `.parallelStream()` on CPU-bound ops sharing a common pool |
| synchronized scope too wide | MEDIUM | Entire method synchronized when only 3 lines need a lock |
| CompletableFuture swallowed error | HIGH | `.thenApply(...)` chain with no `.exceptionally()` or `.handle()` |
| ThreadLocal not cleaned up | HIGH | `ThreadLocal.set()` in a request handler with no `remove()` |
| Raw generic type | MEDIUM | `List list = new ArrayList()` — unchecked operations |
| Mutable collection returned | MEDIUM | `return this.items` exposes internal state directly |
| Checked exception in lambda | MEDIUM | Checked exception caught and swallowed inside a lambda |
| Static mutable state | HIGH | `private static List<X>` mutated by instance methods |
| Resource not in try-with-resources | HIGH | `Connection c = ds.getConnection()` outside try-with-resources |

## Null Safety

Java has no built-in non-null type enforcement. `NullPointerException` is the default failure mode when contracts are violated. Java 8's `Optional<T>` was designed to make absent values explicit in return types, but it is frequently misused in ways that either replicate the original null problem or add overhead without safety.

**Optional.get() without isPresent check** — calling `get()` on an empty Optional throws `NoSuchElementException`, a different exception than NPE but equally unchecked and equally unhelpful.

Before:

```java
Optional<User> user = userRepository.findById(id);
String name = user.get().getName(); // NoSuchElementException if empty
```

After:

```java
Optional<User> user = userRepository.findById(id);
String name = user.map(User::getName).orElse("Unknown");
// Or when absence is a real error:
User u = user.orElseThrow(() -> new UserNotFoundException(id));
```

**Optional as a field or parameter** — Optional was designed as a return type only. Storing Optional in a field or accepting it as a method parameter forces callers to wrap values unnecessarily and serialization frameworks (Jackson, Hibernate) often do not handle Optional fields correctly.

Before:

```java
public class Config {
    private Optional<String> timeout; // serialization breaks; field can itself be null
}
public void process(Optional<String> input) { ... }
```

After:

```java
public class Config {
    private String timeout; // nullable; document with @Nullable if using a nullability tool
}
public void process(String input) { ... } // let callers handle nulls before calling
```

**NullPointerException patterns to flag:** returning null from a method whose declared return type implies a collection (return empty list, not null); chained method calls like `a.getB().getC().getValue()` without null guards; `@Autowired` fields that may not be set in tests. Severity: HIGH for collection nulls (causes NPE at caller with no context), MEDIUM for chained dereference (depends on whether callers guard).

## Stream API

The Stream API encourages a declarative style but imposes a contract: stream operations must be non-interfering (do not modify the source), stateless where possible, and side-effect-free in intermediate operations. Violations cause non-deterministic behavior or silent data corruption.

**Side effects in stream pipelines** — `.map()`, `.filter()`, and other intermediate operations should not mutate shared state. `.forEach()` is the designated terminal for side effects, but even then, mutating an external collection from `.forEach()` breaks when the stream is made parallel.

Before:

```java
List<String> results = new ArrayList<>();
users.stream()
     .filter(u -> u.isActive())
     .map(User::getName)
     .forEach(results::add); // mutation inside terminal; breaks with parallelStream
```

After:

```java
// Java 8+:
List<String> results = users.stream()
    .filter(User::isActive)
    .map(User::getName)
    .collect(Collectors.toList());
// Java 16+: .toList() returns an unmodifiable list directly
```

**Infinite streams without termination** — `Stream.iterate()` and `Stream.generate()` produce infinite sequences. Without `.limit()` or `.takeWhile()`, these exhaust memory or loop forever.

Before:

```java
Stream.iterate(0, n -> n + 1)
      .filter(n -> n % 2 == 0)
      .collect(Collectors.toList()); // OutOfMemoryError
```

After:

```java
Stream.iterate(0, n -> n + 1)
      .filter(n -> n % 2 == 0)
      .limit(100)
      .collect(Collectors.toList());
// Java 9+ takeWhile:
Stream.iterate(0, n -> n < 200, n -> n + 1)
      .filter(n -> n % 2 == 0)
      .toList();
```

**Parallel streams and the common pool** — `.parallelStream()` uses the JVM-wide ForkJoinPool.commonPool(). Blocking or CPU-heavy operations from all parallel streams contend on the same pool, degrading throughput globally. I/O-bound operations should use explicit executor-backed streams or CompletableFuture with a dedicated pool.

Before:

```java
orders.parallelStream()
      .map(o -> callExternalService(o)) // blocking HTTP call on common pool
      .collect(Collectors.toList());
```

After:

```java
ExecutorService pool = Executors.newFixedThreadPool(10);
List<CompletableFuture<Result>> futures = orders.stream()
    .map(o -> CompletableFuture.supplyAsync(() -> callExternalService(o), pool))
    .collect(Collectors.toList());
List<Result> results = futures.stream()
    .map(CompletableFuture::join)
    .collect(Collectors.toList());
```

## Concurrency Pitfalls

Java's concurrency model combines low-level primitives (`synchronized`, `volatile`) with higher-level abstractions (`java.util.concurrent`, `CompletableFuture`). Mixing these incorrectly is the most common source of hard-to-reproduce production bugs.

**Synchronized scope too wide** — synchronizing an entire method when only a small critical section needs a lock holds the monitor longer than necessary, reducing throughput and increasing deadlock risk.

Before:

```java
public synchronized UserStats computeStats(long userId) {
    List<Order> orders = orderService.fetchAll(userId); // slow DB call under lock
    return aggregate(orders);
}
```

After:

```java
public UserStats computeStats(long userId) {
    List<Order> orders = orderService.fetchAll(userId); // DB call outside lock
    synchronized (this) {
        cache.put(userId, orders); // only the cache write needs synchronization
    }
    return aggregate(orders);
}
```

**CompletableFuture error handling** — a CompletableFuture chain where no stage calls `.exceptionally()`, `.handle()`, or `.whenComplete()` silently swallows exceptions. The future completes exceptionally, but without a terminal error handler the exception is never surfaced unless the caller calls `.get()` or `.join()`.

Before:

```java
CompletableFuture.supplyAsync(() -> fetchUser(id))
    .thenApply(user -> buildResponse(user))
    .thenAccept(resp -> sendResponse(resp));
// If fetchUser throws, the exception is swallowed; sendResponse is never called.
```

After:

```java
CompletableFuture.supplyAsync(() -> fetchUser(id))
    .thenApply(user -> buildResponse(user))
    .thenAccept(resp -> sendResponse(resp))
    .exceptionally(ex -> {
        log.error("Failed to process user {}: {}", id, ex.getMessage());
        sendErrorResponse(ex);
        return null;
    });
```

**ThreadLocal leaks in thread pools** — thread pools reuse threads, so a `ThreadLocal` value set during one request is visible during a subsequent unrelated request unless explicitly removed. This causes data leakage between tenants or users in multi-tenant services.

Before:

```java
private static final ThreadLocal<String> tenantId = new ThreadLocal<>();

public void handleRequest(Request req) {
    tenantId.set(req.getTenantId());
    processRequest(req);
    // Missing: tenantId.remove() — next request on this thread sees stale tenant
}
```

After:

```java
public void handleRequest(Request req) {
    tenantId.set(req.getTenantId());
    try {
        processRequest(req);
    } finally {
        tenantId.remove(); // always clean up, even if processRequest throws
    }
}
```

**volatile vs atomic** — `volatile` guarantees visibility but not atomicity. Compound operations like `i++` (read-modify-write) on a volatile field are still a race. Use `AtomicInteger`, `AtomicLong`, or `AtomicReference` for compound operations.

Before:

```java
private volatile int counter = 0;
public void increment() { counter++; } // read-modify-write is not atomic
```

After:

```java
private final AtomicInteger counter = new AtomicInteger(0);
public void increment() { counter.incrementAndGet(); }
```

## Resource Management

Java resources that implement `Closeable` or `AutoCloseable` (streams, connections, readers, channels) must be closed after use. Manual close in a finally block is error-prone. `try-with-resources` (introduced in Java 7) closes all declared resources automatically, even if an exception is thrown.

**Manual resource close vs try-with-resources** — connection pool exhaustion, file handle leaks, and socket exhaustion are the production consequences.

Before:

```java
Connection conn = dataSource.getConnection();
PreparedStatement stmt = conn.prepareStatement(sql);
ResultSet rs = stmt.executeQuery();
// If processResults throws, conn and stmt are never closed.
processResults(rs);
conn.close();
```

After:

```java
try (Connection conn = dataSource.getConnection();
     PreparedStatement stmt = conn.prepareStatement(sql);
     ResultSet rs = stmt.executeQuery()) {
    processResults(rs);
} // conn, stmt, rs all closed automatically in reverse order
```

**AutoCloseable in custom types** — any class that holds a native resource (file handle, socket, connection) should implement `AutoCloseable` so callers can use `try-with-resources`. Failure to implement `AutoCloseable` forces callers into unsafe manual cleanup.

```java
// CORRECT: implement AutoCloseable so callers get automatic cleanup
public class ReportWriter implements AutoCloseable {
    private final BufferedWriter writer;
    public ReportWriter(Path path) throws IOException {
        this.writer = Files.newBufferedWriter(path);
    }
    @Override
    public void close() throws IOException { writer.close(); }
}
// Caller:
try (ReportWriter rw = new ReportWriter(outputPath)) {
    rw.write(report);
}
```

**Connection pool exhaustion** — flag any code that acquires a connection in a loop without try-with-resources, or opens a connection and then conditionally returns early before closing it. Severity: HIGH when the call path can be triggered by user requests; MEDIUM in batch jobs with controlled concurrency.

## Generics and Type Erasure

Java generics are erased at runtime. Concrete type parameters are unavailable via reflection without explicit tokens. Misunderstanding erasure leads to unchecked casts, raw type warnings, and `ClassCastException` at unexpected call sites.

**Raw types** — using a generic class without type parameters disables compile-time checking. The compiler inserts unchecked casts and only catches type errors at runtime.

Before:

```java
List items = new ArrayList(); // raw type — no <T>, no compile-time safety
items.add("hello");
items.add(42);
String s = (String) items.get(1); // ClassCastException at runtime
```

After:

```java
List<String> items = new ArrayList<>();
items.add("hello");
// items.add(42); // compile-time error — caught early
String s = items.get(0);
```

**PECS — Producer Extends, Consumer Super** — wildcards define variance. A method that reads from a collection should use `? extends T`; a method that writes into it should use `? super T`. Mixing these or using `?` without a bound blocks both read and write.

```java
// Correct: reading from a producer
public double sumList(List<? extends Number> numbers) {
    return numbers.stream().mapToDouble(Number::doubleValue).sum();
}
// Correct: writing into a consumer
public void addNumbers(List<? super Integer> dest) {
    dest.add(1);
    dest.add(2);
}
```

**Type erasure and checked casting** — generic type parameters are erased to their bound (or Object) at runtime. Casting to a parameterized type like `(List<String>)` generates an unchecked warning because the cast only verifies the raw type. Use type tokens (`Class<T>`) or pass explicit class references when you need runtime type information.

```java
// WRONG: unchecked cast — only checks List, not List<String>
@SuppressWarnings("unchecked")
List<String> names = (List<String>) getObject(); // silent heap pollution

// CORRECT: validate element type explicitly
Object obj = getObject();
if (obj instanceof List<?> list && list.stream().allMatch(e -> e instanceof String)) {
    List<String> names = list.stream().map(e -> (String) e).toList();
}
```

## Immutability

Java does not enforce immutability at the language level (outside of records), so mutable objects escape their intended scope easily. Defensive copies and unmodifiable wrappers prevent callers from corrupting internal state.

**Unmodifiable collections** — returning a mutable field directly exposes internal state. Callers can mutate it and break invariants without the owning object being aware.

Before:

```java
public class Order {
    private List<LineItem> items = new ArrayList<>();
    public List<LineItem> getItems() { return items; } // caller can call .clear() or .add()
}
```

After:

```java
public class Order {
    private final List<LineItem> items = new ArrayList<>();
    public List<LineItem> getItems() { return Collections.unmodifiableList(items); }
    // Java 10+:
    public List<LineItem> getItems() { return List.copyOf(items); }
}
```

**Record types (Java 16+)** — for simple data carriers, `record` provides an immutable class with canonical constructor, accessors, `equals`, `hashCode`, and `toString` automatically. Flag classes that are pure data holders (no behavior, all-final fields) as candidates for records.

```java
// Before: verbose mutable POJO
public class Point {
    private int x;
    private int y;
    public Point(int x, int y) { this.x = x; this.y = y; }
    public int getX() { return x; }
    public int getY() { return y; }
    // equals, hashCode, toString omitted
}

// After: immutable record
public record Point(int x, int y) {}
```

**Defensive copies** — when accepting a mutable parameter that will be stored, copy it to prevent callers from mutating the stored reference later.

```java
// WRONG: caller retains reference and can mutate after construction
public Config(List<String> allowedRoles) {
    this.allowedRoles = allowedRoles;
}
// CORRECT: defensive copy breaks the aliasing
public Config(List<String> allowedRoles) {
    this.allowedRoles = List.copyOf(allowedRoles);
}
```

## Anti-Patterns

**Checked exception abuse** — checked exceptions force callers to either handle or declare them, which leads to exception swallowing (`catch (Exception e) {}`) or unchecked wrapping throughout the codebase. Flag checked exceptions that cross layer boundaries (e.g., `SQLException` surfacing in a service interface) and empty catch blocks.

```java
// WRONG: empty catch swallows the error silently
try {
    config = loadConfig(path);
} catch (IOException e) {} // caller never knows config is missing

// CORRECT: translate at the boundary and log or rethrow
try {
    config = loadConfig(path);
} catch (IOException e) {
    throw new ConfigurationException("Failed to load config from " + path, e);
}
```

**Static mutable state** — static fields that are mutated by instance methods are shared across all instances and threads. This causes non-deterministic behavior in concurrent applications and breaks test isolation.

```java
// WRONG: shared mutable state
private static List<String> errors = new ArrayList<>();
public void validate(Input input) { errors.add("validation failed"); }

// CORRECT: instance-scoped or thread-local state
private final List<String> errors = new ArrayList<>();
```

**Service locator pattern** — calling `ServiceLocator.get(UserService.class)` inside business logic hides dependencies, making the class hard to test and its contracts invisible. Flag any use of a static registry, `ApplicationContext.getBean()`, or equivalent inside non-configuration code.

**God class** — a class with more than 500 lines, more than 10 injected dependencies, or methods that span unrelated domains. God classes reduce cohesion and increase the blast radius of changes. Flag for decomposition; note specific domain boundaries as a starting point.

## Calibration Notes

Cross-reference `review-accuracy-calibration` before posting. Apply the C4/C3/C2/C1 confidence model:

- **Optional.get() without guard (C4):** Provably throws when Optional is empty; always post as HIGH.
- **ThreadLocal without remove() (C4 in request handlers):** If the class is used in a Servlet, Spring handler, or thread-pool task, this is C4 — post as HIGH. Standalone utility code may be C2.
- **synchronized scope too wide (C3):** Strong anti-pattern with measurable throughput impact; post as MEDIUM. Upgrade to HIGH only if you can identify a deadlock scenario.
- **CompletableFuture missing exception handler (C3):** Post as HIGH when the chain calls external I/O; downgrade to MEDIUM for fully in-memory pipelines where exceptions are already handled by the caller.
- **Raw types (C3):** MEDIUM; unchecked cast at call site is C4. Verify whether the raw type is in a pre-Java-5 compatibility layer before posting.
- **Static mutable state (C3 in concurrent code, C2 in single-threaded utilities):** Confirm concurrency context before escalating to HIGH.
- **God class (C2):** Subjective; frame as a refactoring suggestion unless the class has a confirmed bug stemming from its size.

## Cross-References

- `review-accuracy-calibration` — Apply C4/C3/C2/C1 confidence scoring before posting any Java finding; confirm concurrency and context before escalating severity
- `error-handling-patterns` — Java checked vs unchecked exception taxonomy maps to the Result/Either patterns; use for cross-language comparison on exception boundary design
- `concurrency-patterns` — CompletableFuture and thread pool patterns map to Producer-Consumer and Thread Pool archetypes; use for deeper analysis of async pipelines
- `type-system-patterns` — Java generics and erasure context; use when reviewing reflection-heavy code or frameworks that use type tokens
