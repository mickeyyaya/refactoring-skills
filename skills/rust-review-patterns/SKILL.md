---
name: rust-review-patterns
description: Use when reviewing Rust code — covers ownership and borrowing pitfalls, lifetime annotation discipline, unsafe block justification, error handling with Result/Option, async Send/Sync constraints, trait design, and common anti-patterns. Load alongside review-accuracy-calibration to ensure findings are well-calibrated before posting comments.
---

# Rust Code Review Patterns

## Overview

Rust's ownership model, borrow checker, and zero-cost abstractions create a category of correctness guarantees absent from other systems languages. A reviewer familiar with C++ or Go will miss the failure modes that are unique to Rust: unnecessary clone chains that silently degrade throughput, lifetime annotations that fight the compiler rather than express intent, unsafe blocks that document no invariants, and async code that compiles but deadlocks under real workloads.

This guide focuses on seven areas where Rust code most commonly fails in review or in production: ownership and borrowing discipline, lifetime annotations, unsafe correctness, error handling with Result and Option, async pitfalls around Send and Sync, trait design mistakes, and pervasive anti-patterns like excessive cloning and Arc<Mutex<>> overuse.

Load this skill when reviewing any Rust PR that touches async runtimes, FFI boundaries, public library APIs, or performance-sensitive hot paths. Cross-reference `review-accuracy-calibration` before posting: Rust's compiler rejects most memory safety bugs, but logic errors in unsafe blocks, async cancellation, and error propagation escape static analysis.

## Quick Reference

| Review Dimension | Severity | Primary Red Flag |
|---|---|---|
| Unnecessary clone | MEDIUM–HIGH | `.clone()` on large heap types inside a loop or hot path |
| Fighting the borrow checker | MEDIUM | Re-structuring logic rather than redesigning the data model |
| Move semantics misuse | HIGH | Using a value after move; surprising copies of non-Copy types |
| Lifetime over-annotation | MEDIUM | `'a` on every signature when elision would be correct |
| `'static` abuse | HIGH | `T: 'static` bound used to avoid reasoning about lifetimes |
| Unjustified unsafe | CRITICAL | `unsafe` block with no safety comment documenting invariants |
| `unwrap()` in production | HIGH | `.unwrap()` or `.expect()` in non-test, non-prototype code |
| Missing `?` propagation | MEDIUM | Manual `match` on `Result` when `?` suffices |
| Blocking in async | HIGH | `std::thread::sleep`, `std::fs`, or heavy CPU work inside `async fn` |
| Missing `Send` bound | HIGH | `tokio::spawn` with a future that holds a `!Send` type |
| Trait object over generics | MEDIUM | `dyn Trait` in a hot path where monomorphization is feasible |
| Blanket impl conflict | HIGH | Blanket `impl<T>` that may overlap with future upstream impls |
| `Arc<Mutex<>>` everywhere | MEDIUM | Shared mutable state wrapped per-field rather than modeled differently |
| Ignoring clippy | LOW–MEDIUM | PR touches existing clippy warnings without resolving them |

## Ownership and Borrowing

The borrow checker enforces a contract: at any point in time, a value has either one mutable reference or any number of shared references, never both. Review findings in this area are usually C4 confidence because the compiler makes violations explicit.

**Unnecessary clone — before:**

```rust
fn process_names(names: Vec<String>) -> Vec<String> {
    let mut result = Vec::new();
    for name in names.clone() {   // Clones the entire Vec; `names` is already owned here.
        result.push(name.to_uppercase());
    }
    result
}
```

**After — consume directly or borrow:**

```rust
fn process_names(names: Vec<String>) -> Vec<String> {
    names.into_iter().map(|n| n.to_uppercase()).collect()
}
// If caller needs to retain names: accept &[String] instead.
fn process_names(names: &[String]) -> Vec<String> {
    names.iter().map(|n| n.to_uppercase()).collect()
}
```

**Move after use — before:**

```rust
fn send_report(report: Report, logger: &Logger) {
    send_to_server(report);       // report is moved here
    logger.log(&report.summary);  // COMPILE ERROR: use of moved value
}
```

**After — reorder or borrow the needed field first:**

```rust
fn send_report(report: Report, logger: &Logger) {
    let summary = report.summary.clone(); // or borrow before move
    send_to_server(report);
    logger.log(&summary);
}
```

**Severity rules:** Clone on a `u8` or small Copy type: LOW (compiler would copy anyway). Clone on `Vec`, `String`, `HashMap`, or `Arc`-wrapped heap type in a loop: HIGH. Borrowing pattern that forces an unexpected clone: MEDIUM.

## Lifetime Annotations

Lifetime annotations describe relationships between borrows. The compiler's elision rules cover the majority of cases. Over-annotating obscures intent; under-annotating lets the compiler choose incorrect lifetimes silently.

**Elision rules reviewers must know:**
1. Each reference parameter gets its own lifetime.
2. If there is exactly one input lifetime, all output lifetimes get it.
3. If one input is `&self` or `&mut self`, the output lifetime gets that lifetime.

**Over-annotated — before:**

```rust
fn first_word<'a>(s: &'a str) -> &'a str {
    // Rule 2 applies: single input reference → output gets same lifetime.
    // Explicit 'a adds noise without new information.
    s.split_whitespace().next().unwrap_or("")
}
```

**After — let elision do the work:**

```rust
fn first_word(s: &str) -> &str {
    s.split_whitespace().next().unwrap_or("")
}
```

**`'static` abuse — before:**

```rust
// Forces caller to provide an owned or leaked value; rules out stack-allocated data.
fn register_handler(name: &'static str, handler: Box<dyn Fn() + 'static>) {
    HANDLERS.lock().unwrap().insert(name, handler);
}
```

**After — use a bounded lifetime or `Arc` to model ownership correctly:**

```rust
fn register_handler(name: String, handler: Arc<dyn Fn() + Send + Sync>) {
    HANDLERS.lock().unwrap().insert(name, handler);
}
```

**Severity:** `'static` bound on a public API that accepts caller-supplied data: HIGH (restricts all callers to 'static data or leaks). Redundant `'a` annotation that matches elision output: LOW. Lifetime annotation that hides an ownership design problem: MEDIUM.

## Unsafe Blocks

`unsafe` in Rust is a contract: the programmer asserts that invariants the compiler cannot verify are upheld. Without documentation, reviewers cannot check the contract.

**Requirement: every `unsafe` block must have a `// SAFETY:` comment** explaining which invariant is being upheld and why it holds.

**Unjustified unsafe — before:**

```rust
fn read_offset(ptr: *const u8, offset: usize) -> u8 {
    unsafe { *ptr.add(offset) }   // No safety comment. Reviewer cannot check validity.
}
```

**After — with documented invariant:**

```rust
/// Reads a byte at `offset` within the buffer `ptr` points to.
///
/// # Safety
/// - `ptr` must be non-null and aligned for `u8`.
/// - `ptr.add(offset)` must be within the same allocated object.
/// - The memory must remain valid and unaliased for the duration of this call.
fn read_offset(ptr: *const u8, offset: usize) -> u8 {
    // SAFETY: Caller guarantees ptr is non-null, add(offset) is in-bounds,
    // and the pointed-to memory is valid and exclusively borrowed here.
    unsafe { *ptr.add(offset) }
}
```

**FFI boundaries** — all values crossing `extern "C"` are `unsafe` territory. Review that:
- Pointer arguments document nullability assumptions.
- Lifetime of borrowed data outlives any pointer passed to C.
- C-side mutations through shared pointers are serialized.

**When unsafe is justified:** Raw pointer arithmetic for SIMD or zero-copy parsing; FFI to C libraries where the Rust wrapper provides a safe API; `std::mem::transmute` between types with identical representation (must be documented); `unsafe impl Send` / `unsafe impl Sync` for types with manual synchronization.

**Severity:** `unsafe` block with no `// SAFETY:` comment: CRITICAL. `unsafe` block that can be replaced by safe Rust: HIGH. `unsafe` block with correct safety comment: C4 confidence — leave feedback only if the invariant reasoning is incomplete.

## Error Handling

Rust error handling uses `Result<T, E>` and `Option<T>`. The `?` operator propagates errors up the call stack, but only when the error types are compatible.

**unwrap in production — before:**

```rust
fn load_config(path: &str) -> Config {
    let text = std::fs::read_to_string(path).unwrap();   // Panics if file missing.
    toml::from_str(&text).expect("invalid config format") // Panics on malformed TOML.
}
```

**After — propagate errors with Result:**

```rust
#[derive(Debug, thiserror::Error)]
enum ConfigError {
    #[error("could not read config file at {path}: {source}")]
    Io { path: String, #[source] source: std::io::Error },
    #[error("invalid TOML in config file: {0}")]
    Parse(#[from] toml::de::Error),
}

fn load_config(path: &str) -> Result<Config, ConfigError> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| ConfigError::Io { path: path.to_owned(), source: e })?;
    Ok(toml::from_str(&text)?)
}
```

**thiserror vs anyhow:**
- `thiserror` — for library crates that expose typed errors callers can match on.
- `anyhow` — for application code where the error is displayed to a user or logged; not for library APIs.
- Mixing `anyhow::Error` into a library's public return type forces callers to downcast; flag as MEDIUM.

**Option discipline:**

```rust
// WRONG: .unwrap() on Option panics at runtime when None.
let first = items.first().unwrap();

// CORRECT: handle None explicitly or use `?` in a function returning Option.
let first = items.first().ok_or(Error::EmptyList)?;
```

**Severity:** `.unwrap()` or `.expect()` in non-test, non-`main` code: HIGH. Manual `match Ok(v) => v, Err(e) => return Err(e)` where `?` applies: MEDIUM. `anyhow::Error` in a public library return type: MEDIUM.

## Async Pitfalls

Rust's async model compiles futures into state machines. Correctness depends on correct `Send`/`Sync` bounds and avoiding blocking operations inside async executors.

**Missing Send bound — before:**

```rust
async fn handle_request(req: Request) -> Response {
    let conn = Rc::new(DbConn::new()); // Rc<T> is !Send.
    process(conn, req).await           // COMPILE ERROR if spawned with tokio::spawn.
}

tokio::spawn(handle_request(req));     // Error: future is not Send.
```

**After — use Arc instead of Rc for shared async state:**

```rust
async fn handle_request(req: Request) -> Response {
    let conn = Arc::new(DbConn::new()); // Arc<T> is Send if T: Send + Sync.
    process(conn, req).await
}
```

**Blocking in async context — before:**

```rust
async fn read_file(path: &str) -> Vec<u8> {
    std::fs::read(path).unwrap() // Blocks the executor thread; starves other tasks.
}
```

**After — use async I/O or spawn_blocking:**

```rust
async fn read_file(path: &str) -> Result<Vec<u8>, std::io::Error> {
    tokio::fs::read(path).await          // Non-blocking async I/O.
}
// For CPU-bound work:
let result = tokio::task::spawn_blocking(|| expensive_cpu_work()).await?;
```

**`Pin` and self-referential futures** — flag any manual `Pin` implementation that does not also implement `Unpin` correctly. Prefer `pin_project` or `pin_project_lite` over hand-rolled `Pin` projections.

**Cancellation safety** — an `async fn` can be cancelled at any `.await` point. Review that:
- Partially-written state is not left in an inconsistent form.
- Mutexes are released before every `.await` (or use `tokio::sync::Mutex`).
- Channels are not left in a state where a message is consumed but the side effect is not committed.

**Severity:** Blocking call inside `async fn` on the executor thread: HIGH. `Rc` or `Cell` in a `tokio::spawn` future: HIGH (compile error in most cases, but may appear in conditional paths). Mutex held across `.await`: HIGH. Manual `Pin` projection without `pin_project`: MEDIUM.

## Trait Design

Traits define shared behavior. Poor trait design creates coupling that is difficult to reverse because trait implementations become part of a library's public API.

**Trait objects vs generics:**

```rust
// Trait object (dyn Trait): dynamic dispatch, single vtable per call.
// Use when: the concrete type is not known at compile time, or you need
// heterogeneous collections.
fn notify(handlers: &[Box<dyn Handler>]) { ... }

// Generic (impl Trait / T: Trait): monomorphized, zero-cost, but inflates binary.
// Use in hot paths where dispatch cost is measurable.
fn notify<H: Handler>(handler: &H) { ... }
```

Flag `dyn Trait` in a known-hot-path where the concrete type set is closed and small: MEDIUM.

**Orphan rule** — you can only implement a trait for a type if either the trait or the type is defined in your crate. Reviewers should flag workarounds that use newtype wrappers solely to bypass the orphan rule without documenting why: LOW–MEDIUM.

**Blanket impl risks — before:**

```rust
// Implements Display for every T that implements Debug.
// Will conflict with std's own Display impls if upstream adds one.
impl<T: Debug> Display for T { ... }  // ERROR: conflicting impl.
```

**After — use sealed trait or narrow the impl:**

```rust
// Sealed trait pattern restricts external implementations.
mod private { pub trait Sealed {} }
pub trait MyTrait: private::Sealed { fn method(&self); }
impl private::Sealed for MyType {}
impl MyTrait for MyType { fn method(&self) { ... } }
```

**Default method abuse** — trait default methods that do meaningful work without calling required methods create surprising behavior when types override only some methods. Review that defaults are either trivially safe (returning a constant, calling another required method) or clearly documented.

**Severity:** Blanket impl that may conflict with upstream: HIGH. `dyn Trait` in an internal hot path: MEDIUM. Trait with more than 5 methods that could be split: MEDIUM.

## Anti-Patterns

**Excessive `.clone()`** — the most common performance regression in Rust. Flag `.clone()` calls on `String`, `Vec`, `HashMap`, or other heap-allocated types inside loops or high-frequency functions. Check whether the caller can pass a reference, the API can accept `Into<T>`, or the data can be shared with `Arc`.

**Stringly-typed APIs** — using `String` or `&str` where a type, enum, or newtype would encode validity:

```rust
// WRONG: caller can pass any string; errors surface at runtime.
fn set_log_level(level: &str) { ... }

// CORRECT: invalid levels are compile errors.
enum LogLevel { Debug, Info, Warn, Error }
fn set_log_level(level: LogLevel) { ... }
```

**`Arc<Mutex<T>>` everywhere** — wrapping every shared value in `Arc<Mutex<>>` is a design smell, not a solution. It serializes all access, eliminates the benefit of async, and hides data model problems. Review whether the state can be owned by one task and accessed via message passing, or whether `RwLock` is appropriate for read-heavy workloads.

**Ignoring clippy** — Rust's clippy linter catches a wide class of correctness and performance issues that manual review misses. A PR that introduces new clippy warnings without a documented suppression (`#[allow(clippy::...)]` with a comment) should be flagged as LOW–MEDIUM depending on the warning category.

**Panic in library code** — `panic!`, `unreachable!`, and `todo!` in non-test library code force callers to handle process exits. Replace with `Result` or `Option` at API boundaries.

## Calibration Notes

Apply the C4/C3/C2/C1 confidence model from `review-accuracy-calibration` before posting any finding.

- **Ownership and borrow issues (C4):** The compiler catches these. Flag only when a pattern compiles but carries hidden cost (unnecessary clone) or surprising semantics (move in a loop).
- **Unsafe blocks (C4 for missing SAFETY comment):** Absence of a `// SAFETY:` comment is always C4 — it is a documentation gap, not a code dispute.
- **Async blocking (C3–C4):** Confirm the executor is thread-pool-based (tokio multi-thread) before flagging CPU work. Single-threaded executors have different constraints.
- **Lifetime `'static` abuse (C3):** Check if the bound is required by a third-party constraint (e.g., `std::thread::spawn`) before flagging as an author error.
- **Trait design (C2–C3):** Orphan rule workarounds and blanket impl risks require understanding the full crate graph. Do not flag C1 without verifying the conflict exists.

## Cross-References

- `review-accuracy-calibration` — Apply C4/C3/C2/C1 confidence scoring before posting any Rust finding; use the calibration table to distinguish high-confidence from speculative comments
- `error-handling-patterns` — Broader error handling across languages; Rust Result/Option maps to functional Either/Maybe and exception hierarchy patterns
- `concurrency-patterns` — Rust async and channel patterns map to Producer-Consumer and Actor models; use for tokio::select, bounded channels, and backpressure
- `type-system-patterns` — Rust newtype, typestate, and sealed trait patterns are covered in depth alongside TypeScript branded types and Haskell phantom types
