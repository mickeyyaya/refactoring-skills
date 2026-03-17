---
name: go-review-patterns
description: Use when reviewing Go code — covers goroutine leak detection, context propagation rules, error handling patterns (sentinel vs typed vs wrapped), slice/map pitfalls, interface design, nil traps, and common anti-patterns. Load alongside review-accuracy-calibration to ensure findings are well-calibrated before posting comments.
---

# Go Code Review Patterns

## Overview

Go has a small surface area but a unique set of failure modes that do not appear in other languages. Explicit error returns, a cooperative concurrency model built on goroutines, and structural typing through interfaces create patterns that look fine to reviewers from other backgrounds but silently break under load or in error paths.

This guide focuses on six areas where Go code most commonly fails in production: goroutine leaks, context propagation gaps, error handling discipline, slice/map pitfalls, interface design mistakes, and nil traps.

Load this skill when reviewing any Go PR that touches HTTP handlers, background workers, data access layers, or any code that spawns goroutines. Cross-reference `review-accuracy-calibration` before posting — Go has low false positive risk overall, but goroutine and nil interface bugs are easy to miss in small diffs.

## Quick Reference

| Review Dimension | Severity | Primary Red Flag |
|---|---|---|
| Goroutine leak | HIGH | `go func()` with no termination path in the spawning scope |
| Missing context cancellation | HIGH | Goroutine does I/O with no `ctx.Done()` case in select |
| Context stored in struct | MEDIUM | `type Foo struct { ctx context.Context }` |
| Context not passed to I/O | MEDIUM | `db.Query(sql)` instead of `db.QueryContext(ctx, sql)` |
| Ignored error on I/O | HIGH | `f, _ := os.Open(...)` — error discarded with blank identifier |
| Error compared with `==` | HIGH | `if err == ErrNotFound` instead of `errors.Is(err, ErrNotFound)` |
| Nil map write | CRITICAL | `var m map[string]int; m["key"] = 1` — panics at runtime |
| Nil interface trap | HIGH | Returning typed nil as `error` — never nil-checks to true |
| Concurrent map read/write | CRITICAL | Map accessed from multiple goroutines without `sync.RWMutex` |
| Slice append aliasing | MEDIUM | Shared underlying array after append with sufficient capacity |
| Exported interface from impl package | MEDIUM | Interface defined in same package as its only implementation |
| `defer` inside loop | HIGH | `defer f.Close()` in `for` loop — defers accumulate until function exit |
| `init()` with side effects | MEDIUM | `func init()` dialing network, registering globals, reading files |
| Empty `interface{}` / `any` abuse | LOW–MEDIUM | Public API fields typed `any` masking a design problem |

## Goroutine Leak Detection

A goroutine leak occurs when a goroutine starts but has no path to termination, holding memory, file handles, or database connections indefinitely.

**Red flags:** `go func()` with no `ctx.Done()` or done channel; goroutines in a loop without a `WaitGroup` or bound; a channel written to but never read; a channel read but never closed.

**Before — goroutine leak:**

```go
func processItems(items []Item) {
    for _, item := range items {
        go func(i Item) {
            // No termination signal. If caller returns early (e.g., context cancelled),
            // this goroutine continues running and holds all resources it touches.
            result := expensiveOp(i)
            saveResult(result)
        }(item)
    }
    // Caller returns; goroutines are orphaned.
}
```

**After — bounded and cancellable:**

```go
func processItems(ctx context.Context, items []Item) error {
    var wg sync.WaitGroup
    errCh := make(chan error, len(items))
    for _, item := range items {
        wg.Add(1)
        go func(i Item) {
            defer wg.Done()
            select {
            case <-ctx.Done():
                errCh <- ctx.Err()
                return
            default:
            }
            result, err := expensiveOp(ctx, i)
            if err != nil {
                errCh <- err
                return
            }
            if err := saveResult(ctx, result); err != nil {
                errCh <- err
            }
        }(item)
    }
    wg.Wait()
    close(errCh)
    for err := range errCh {
        if err != nil {
            return err
        }
    }
    return nil
}
```

**Severity:** HIGH. Leaked goroutines accumulate over time. A server processing 1000 req/hr with one leaked goroutine per request will exhaust memory within hours.

**`defer` inside a loop** is a related goroutine-adjacent mistake. Deferred calls accumulate until the enclosing function exits, not each loop iteration:

```go
// WRONG — all Close() calls run when readFiles returns, holding all files open meanwhile.
func readFiles(paths []string) error {
    for _, p := range paths {
        f, err := os.Open(p)
        if err != nil { return err }
        defer f.Close()
        process(f)
    }
    return nil
}
// CORRECT — extract to a helper so defer runs at end of each call.
func readFile(path string) error {
    f, err := os.Open(path)
    if err != nil { return err }
    defer f.Close()
    process(f)
    return nil
}
```

## Context Propagation

**Rules:** `context.Context` is always the first parameter of functions that do I/O. Never store a `context.Context` in a struct field. Pass `ctx` to every database, HTTP, and gRPC call that accepts it. Do not create `context.Background()` deep inside a call stack when a `ctx` parameter is already available.

**Before — context stored in struct, I/O bypass:**

```go
type UserService struct {
    ctx context.Context  // WRONG: stored context; caller cancellation breaks.
    db  *sql.DB
}
func (s *UserService) GetUser(id int) (*User, error) {
    row := s.db.QueryRowContext(s.ctx, "SELECT * FROM users WHERE id = ?", id)
    // ...
}
```

**After — context as parameter, propagated to I/O:**

```go
type UserService struct{ db *sql.DB }

func (s *UserService) GetUser(ctx context.Context, id int) (*User, error) {
    row := s.db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = ?", id)
    // If caller's context is cancelled, QueryRowContext returns immediately.
    // ...
}
```

**Red flags to flag:** `context.Background()` inside a function that already receives `ctx` (outer cancellation dropped); `db.Query(...)` instead of `db.QueryContext(ctx, ...)`; `http.Get(url)` instead of `http.NewRequestWithContext(ctx, ...)`.

## Error Handling Patterns

| Style | Declaration | Correct comparison | Breaks when |
|---|---|---|---|
| Sentinel error | `var ErrNotFound = errors.New("not found")` | `errors.Is(err, ErrNotFound)` | Using `==` after wrapping |
| Typed error | `type NotFoundError struct{ ID int }` | `errors.As(err, &nfe)` | Direct type assertion after wrapping |
| Wrapped error | `fmt.Errorf("getUserByID %d: %w", id, err)` | `errors.Is` / `errors.As` on cause | Wrapping with `%v` loses chain |

**Before — errors swallowed, compared wrong:**

```go
func getUser(id int) (*User, error) {
    u, err := db.QueryUser(id)
    if err != nil {
        if err == ErrNotFound { return nil, nil } // WRONG: == breaks if QueryUser wraps ErrNotFound.
        return nil, err  // No context — caller cannot tell which operation failed.
    }
    return u, nil
}
func handler(w http.ResponseWriter, r *http.Request) {
    id, _ := strconv.Atoi(r.URL.Query().Get("id")) // Ignored error.
    u, _ := getUser(id)  // WRONG: error completely discarded.
    json.NewEncoder(w).Encode(u)
}
```

**After — errors wrapped, compared with errors.Is, not ignored:**

```go
func getUser(ctx context.Context, id int) (*User, error) {
    u, err := db.QueryUser(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("getUser %d: %w", id, err)
    }
    return u, nil
}
func handler(w http.ResponseWriter, r *http.Request) {
    id, err := strconv.Atoi(r.URL.Query().Get("id"))
    if err != nil { http.Error(w, "invalid id", http.StatusBadRequest); return }
    u, err := getUser(r.Context(), id)
    if err != nil {
        if errors.Is(err, ErrNotFound) { http.Error(w, "not found", http.StatusNotFound); return }
        http.Error(w, "internal error", http.StatusInternalServerError)
        return
    }
    json.NewEncoder(w).Encode(u)
}
```

**Severity rules:** Ignored error on I/O or DB: HIGH. `err == SentinelErr` instead of `errors.Is`: HIGH (silently breaks when wrapping is added). Error wrapped with `%v` instead of `%w`: MEDIUM. Bare `return err` with no added context: LOW.

## Slice and Map Pitfalls

**Nil slice vs empty slice:**

```go
var s []string         // nil slice — json.Marshal produces null
s := []string{}       // empty slice — json.Marshal produces []
```

APIs returning collections should use `[]string{}` or `make([]T, 0, n)` to avoid `null` in JSON responses.

**Append aliasing** — shared underlying array when capacity is sufficient:

```go
base := make([]int, 3, 10)
extended := append(base, 4)
extended[0] = 99
fmt.Println(base[0]) // 99 — base was silently mutated.
// Fix: copy before appending when the slice will be mutated independently.
```

**Concurrent map access** — CRITICAL: reading and writing a plain map from multiple goroutines is a data race that panics under the race detector and can corrupt memory in production:

```go
// WRONG
var cache = map[string]string{}
func set(k, v string) { cache[k] = v }  // data race
func get(k string) string { return cache[k] }

// CORRECT — sync.RWMutex for read-heavy maps
var mu sync.RWMutex
func set(k, v string) { mu.Lock(); cache[k] = v; mu.Unlock() }
func get(k string) string { mu.RLock(); defer mu.RUnlock(); return cache[k] }
```

**Pre-allocation** — flag repeated append to an uninitialized slice when the length is known:

```go
// MEDIUM: O(n log n) allocations
var ids []int
for _, u := range users { ids = append(ids, u.ID) }

// CORRECT: single allocation
ids := make([]int, 0, len(users))
for _, u := range users { ids = append(ids, u.ID) }
```

## Interface Design

**Accept interfaces, return structs** — callers define the interface they need; implementations return concrete types:

```go
// WRONG: returning an interface forces callers to type-assert for concrete methods.
func NewCache() Cache { return &memCache{} }
// CORRECT: return the concrete type; let callers define their own interface.
func NewCache() *MemCache { return &MemCache{} }
```

**Keep interfaces small** (1-2 methods is ideal). Large interfaces are hard to mock and couple callers to implementation details. Define the interface at the point of use, with only the methods the caller needs — Go's structural typing makes this seamless.

**Do not export interfaces from the package that implements them.** If a package defines both the interface and its only implementation, the interface adds no abstraction. Move it to the consuming package.

## Nil Traps

**Nil interface vs nil pointer in interface** — the most surprising nil behavior in Go:

```go
// WRONG: returns a typed nil — the interface value is NOT nil.
func validate(u *User) error {
    var err *ValidationError        // typed nil pointer
    if u.Name == "" {
        err = &ValidationError{Field: "name"}
    }
    return err  // When u.Name != "", this is (*ValidationError)(nil) wrapped in error — not nil.
}
if err := validate(u); err != nil { /* always entered — bug */ }

// CORRECT: return untyped nil directly.
func validate(u *User) error {
    if u.Name == "" { return &ValidationError{Field: "name"} }
    return nil  // untyped nil — interface value is nil.
}
```

**Nil map write** — reading a nil map is safe (returns zero value); writing panics:

```go
var m map[string]int
m["key"] = 1  // CRITICAL: panic "assignment to entry in nil map"
// Fix: m := make(map[string]int)
```

**Nil channel** — send, receive, and close on a nil channel all block or panic. Nil channels are only useful inside a `select` to disable a case dynamically.

## Anti-Patterns

**Over-use of `init()`** — `init()` runs automatically with no caller control, no error return, and no cancellation. Flag `init()` functions that dial network connections, register global state, or read files. Prefer explicit initialization in `main()` or a named constructor.

**Package-level mutable state** — package-level `var` fields mutated by concurrent handlers are data races. Use `sync/atomic` types or encapsulate in a struct with a mutex.

**`any` / `interface{}` abuse** — flag `any` on public API boundaries (MEDIUM) and struct fields where the concrete type is known (MEDIUM). Test helper parameters are acceptable (LOW).

**Ignoring `go vet` warnings** — common issues reviewers should manually check when CI does not run `go vet`: wrong format verb type, unreachable code in switch, and `sync.Mutex` copied by value (must always be passed by pointer or embedded by address).

## Calibration Notes

- **Goroutine issues:** Require seeing the full lifecycle before posting HIGH. A goroutine that looks unbounded may be bounded by the parent context. Expand context by 20+ lines.
- **Error comparison:** `err == SentinelErr` is C4 if the sentinel crosses a package boundary. Within a single package where wrapping is not done, it may be C2.
- **Concurrent map access:** Flag CRITICAL only if you can confirm the function is called concurrently. Check whether the map is read-only after initialization.
- **Context in struct:** MEDIUM, not HIGH — design smell, not always a runtime bug. The bug appears when the stored context is cancelled but the method continues using it.

## Cross-References

- `review-accuracy-calibration` — Apply confidence scoring before posting any Go finding; see the Go-specific calibration table in that skill
- `error-handling-patterns` — Broader error handling patterns across languages; Go sentinel/typed/wrapped taxonomy maps to Result/Either and Exception hierarchy patterns
- `concurrency-patterns` — Goroutine patterns map to Producer-Consumer and Thread Pool; use for channel mechanics and lock-free data structures
- `performance-anti-patterns` — Cross-reference before posting pre-allocation or map/slice performance findings to confirm measurable impact
