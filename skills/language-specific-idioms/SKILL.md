---
name: language-specific-idioms
description: Use when reviewing code for language-specific correctness — covers idiomatic patterns, common anti-idioms, and code review red flags for TypeScript/JavaScript, Python, Java, Go, Rust, and C++, with before/after examples and a quick reference table
---

# Language-Specific Idioms for Code Review

## Overview

Every language has a "grain" — idiomatic patterns that align with the language's type system, memory model, and standard library. Code that fights the grain is harder to read, more error-prone, and often slower. Use this guide during code review to catch anti-idiomatic patterns before they become technical debt. Each section includes specific red flags to spot in a PR diff.

## When to Use

- Reviewing a PR written in a language you know well but the author may not
- Onboarding new contributors who write Java in Python or C in Go
- Evaluating code for idiomaticity beyond functional correctness
- Any cross-language team where contributors swap languages frequently

## Quick Reference

| Language | Core Idiom | Top Red Flag |
|----------|-----------|--------------|
| TypeScript/JS | Destructuring, optional chaining, `readonly` types | `var`, `any`, `==` instead of `===` |
| Python | Comprehensions, context managers, generators, type hints | C-style `for` loop, mutable default args, bare `except` |
| Java | `Optional`, streams, records, try-with-resources | `null` returns, raw types, checked exception abuse |
| Go | Error returns, interfaces, goroutines+channels, `defer` | `panic` for control flow, interface pollution |
| Rust | Ownership, `Result`/`Option` chaining (`?`), iterators | `unwrap()` everywhere, defensive `clone()` |
| C++ | RAII, smart pointers, `const` correctness, move semantics | Raw `new`/`delete`, C-style casts, `void*` |

---

## TypeScript / JavaScript

### Idiomatic Patterns

- **Destructuring** — extract fields at call site, not inside the function body
- **Optional chaining** (`?.`) and **nullish coalescing** (`??`) — safe navigation without null checks
- **Array methods** (`map`, `filter`, `reduce`, `flatMap`) over imperative loops
- **`async`/`await`** over raw Promise chains for linear readability
- **`readonly` types** and `as const` — enforce immutability at the type level
- **`const`/`let`** exclusively — `var` is scoped to the function, not the block

```typescript
// BEFORE — verbose, var-scoped, manual null check
function getCity(user) {
  var city = null;
  if (user && user.address && user.address.city) {
    city = user.address.city;
  }
  return city || 'Unknown';
}

// AFTER — destructuring + optional chaining + nullish coalescing
function getCity({ address }: User): string {
  return address?.city ?? 'Unknown';
}
```

### Common Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `var x = ...` | `const x = ...` or `let x = ...` |
| `param: any` | Specific type, union, or generic |
| `a == b` | `a === b` |
| Manual prototype: `Foo.prototype.bar = ...` | `class Foo { bar() {} }` |
| `new Promise((res, rej) => { ... })` wrapping an `async` function | Just `async function` directly |
| `arr.forEach(async item => ...)` | `await Promise.all(arr.map(async item => ...))` |

### Code Review Red Flags

- `var` anywhere in modern TypeScript — indicates unfamiliarity with block scoping
- `any` type in function signatures — disables type checking for callers
- `== null` instead of `=== null` — `==` coerces `undefined` to match `null`, which is sometimes intentional but usually a bug waiting to happen
- `await` inside `forEach` — the loop does not wait; iterations run sequentially with no parallelism and errors are swallowed
- Callback-based async inside an `async` function without promisification — mixes two concurrency models
- Missing `readonly` on arrays passed across module boundaries — mutation may be accidental

---

## Python

### Idiomatic Patterns

- **List/dict/set comprehensions** — prefer over explicit `for` loops that build a collection
- **Context managers** (`with`) — guarantee resource cleanup; applies to files, locks, DB connections, HTTP sessions
- **Generators** — lazy sequences that avoid loading entire collections into memory
- **f-strings** — readable, fast, and type-checked by linters; prefer over `%` formatting or `.format()`
- **`dataclasses`** and **`NamedTuple`** — structured data without boilerplate `__init__`
- **Type hints** — `def fn(x: int) -> str` makes interfaces explicit and enables `mypy` checking
- **Pythonic iteration** — `enumerate()` for index+value, `zip()` for parallel iteration

```python
# BEFORE — C-style loop, no type hints, string formatting with %
def get_names(users):
    names = []
    for i in range(len(users)):
        names.append(users[i]['name'].upper())
    return names

# AFTER — comprehension + type hints + f-string in broader context
def get_names(users: list[dict[str, str]]) -> list[str]:
    return [user['name'].upper() for user in users]
```

```python
# BEFORE — manual file close, mutable default arg, bare except
def read_lines(path, result=[]):   # mutable default: persists across calls!
    try:
        f = open(path)
        result.extend(f.readlines())
        f.close()
    except:                        # catches KeyboardInterrupt, SystemExit, etc.
        pass
    return result

# AFTER — context manager, immutable default, specific exception
def read_lines(path: str, result: list[str] | None = None) -> list[str]:
    output = result if result is not None else []
    try:
        with open(path, encoding='utf-8') as f:
            output.extend(f.readlines())
    except OSError as exc:
        raise RuntimeError(f"Failed to read {path}") from exc
    return output
```

### Common Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `for i in range(len(xs)): xs[i]` | `for x in xs:` or `enumerate(xs)` |
| `def fn(items=[])` mutable default | `def fn(items: list \| None = None)` |
| `except:` bare | `except SpecificError as e:` |
| `"Hello " + name` | `f"Hello {name}"` |
| `isinstance(x, A) or isinstance(x, B) or ...` | `isinstance(x, (A, B))` or `match x:` |
| `x.keys()` iteration | `for key in x:` |

### Code Review Red Flags

- Mutable default argument (`def fn(data=[])`) — the default is evaluated once at function definition; all callers share the same list object
- Bare `except:` — catches `SystemExit`, `KeyboardInterrupt`, and `GeneratorExit`, preventing clean shutdown
- `% s` string formatting — slower than f-strings, does not support `__format__` protocol, harder to read
- Missing type hints on public functions — prevents static analysis and makes refactoring unsafe
- `range(len(xs))` for index iteration — `enumerate(xs)` is clearer and avoids off-by-one risks
- Class with only `__init__` setting fields — use `@dataclass` to eliminate boilerplate and get `__repr__`, `__eq__` for free

---

## Java

### Idiomatic Patterns

- **`Optional<T>`** — explicit nullable return; callers must decide how to handle absence
- **Streams** — `filter`, `map`, `collect` over imperative loops for data transformations
- **Records** — immutable data carriers with auto-generated `equals`, `hashCode`, `toString`
- **Sealed classes** — exhaustive type hierarchies without unchecked downcasts
- **Try-with-resources** — `AutoCloseable` resources are closed regardless of exceptions
- **`var`** (Java 10+) — local type inference; use for obvious right-hand sides
- **`@Override`** — always annotate; the compiler catches signature mismatches

```java
// BEFORE — null return, raw type, explicit loop
public List getActiveUsers(List users) {
    List active = new ArrayList();
    for (int i = 0; i < users.size(); i++) {
        User u = (User) users.get(i);
        if (u.isActive()) active.add(u);
    }
    return active;
}

// AFTER — typed generics, stream, no null
public List<User> getActiveUsers(List<User> users) {
    return users.stream()
        .filter(User::isActive)
        .collect(Collectors.toUnmodifiableList());
}
```

### Common Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| Returning `null` | Return `Optional<T>` or throw a domain exception |
| Raw types `List`, `Map` | Parameterized `List<T>`, `Map<K,V>` |
| `str1 == str2` for strings | `str1.equals(str2)` |
| Checked exceptions for unrecoverable errors | `RuntimeException` subclass |
| Mutable beans with setters | Records or immutable value objects |
| `try { ... } catch (Exception e) {}` | Log and rethrow or handle specifically |

### Code Review Red Flags

- `null` return from a method that may not find a result — forces every caller to null-check; use `Optional<T>` instead
- Raw types (`List`, `Map` without generics) — disables compile-time type checking; `unchecked` warnings at runtime
- `obj1 == obj2` to compare non-primitives — compares references, not value equality; use `.equals()`
- Checked exceptions declared on methods that wrap I/O inside business logic — forces callers to handle infrastructure errors; use unchecked exceptions with cause chaining
- Mutable JavaBeans passed across thread or service boundaries — invisible mutation; use records or `Collections.unmodifiableList()`
- Missing `@Override` — a renamed superclass method silently breaks the override with no compiler error

---

## Go

### Idiomatic Patterns

- **Error returns** — functions return `(T, error)`; callers handle errors immediately, not via exceptions
- **Interface satisfaction** — interfaces are satisfied implicitly; define small, focused interfaces at the point of use
- **Goroutines + channels** — structured concurrency via `go func()` and typed channels
- **`defer`** — cleanup runs on function exit regardless of return path; avoids missing `Close()`/`Unlock()` calls
- **Short variable declarations** (`:=`) — infer type from right-hand side
- **Table-driven tests** — slice of `{name, input, want}` structs with a single `t.Run` loop

```go
// BEFORE — error ignored, named return used invisibly, panic for validation
func divide(a, b float64) (result float64) {
    if b == 0 {
        panic("division by zero")  // panic for expected condition
    }
    result = a / b
    return  // naked return — unclear at a glance
}

// AFTER — explicit error return, named return avoided, defer for tracing
func divide(a, b float64) (float64, error) {
    if b == 0 {
        return 0, fmt.Errorf("divide: divisor must be non-zero")
    }
    return a / b, nil
}
```

### Common Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `panic` for expected errors | Return `(T, error)` |
| Large `init()` functions | Explicit constructor functions |
| Fat interfaces (many methods) | Focused single-method or two-method interfaces |
| Naked returns in functions > 5 lines | Explicit return values |
| `errors.New(fmt.Sprintf(...))` | `fmt.Errorf("ctx: %w", err)` |
| Goroutine without lifecycle control | Pass `context.Context` or use `errgroup` |

### Code Review Red Flags

- `panic` in library code for input validation — panics crash the entire program; return errors instead
- `func init()` with side effects (opening DB connections, reading files) — makes the package hard to test and import order fragile
- Interface with 5+ methods defined in the same package that produces the concrete type — Go interfaces are for consumers, not producers; move the interface to where it is used
- Naked `return` in a function longer than a few lines — the reader cannot tell what is being returned without scrolling back to the top
- Goroutine started without a way to signal it to stop — goroutine leak; pass `context.Context` and select on `ctx.Done()`
- Missing `defer mu.Unlock()` immediately after `mu.Lock()` — unlock can be skipped on early return

---

## Rust

### Idiomatic Patterns

- **Ownership and borrowing** — pass references (`&T`, `&mut T`) rather than cloning; the borrow checker enforces correctness at compile time
- **`Result<T, E>` and `Option<T>` chaining** — use `?` to propagate errors without boilerplate; use `.map()`, `.and_then()`, `.unwrap_or_else()`
- **Pattern matching** — exhaustive `match` over enums; use `if let` and `while let` for single-variant checks
- **Iterators** — `iter()`, `map()`, `filter()`, `collect()` compose lazily; avoid manual index loops
- **Derive macros** — `#[derive(Debug, Clone, PartialEq)]` for value types; avoids hand-written boilerplate
- **Lifetimes** — explicit lifetime annotations when the borrow checker cannot infer them; prefer returning owned values from public APIs

```rust
// BEFORE — unwrap() everywhere, unnecessary clone, manual loop
fn find_admin(users: Vec<User>) -> Option<User> {
    let users_clone = users.clone();  // unnecessary
    for i in 0..users_clone.len() {
        if users_clone[i].role == Role::Admin {
            return Some(users_clone[i].clone());
        }
    }
    None
}

// AFTER — iterator, borrow instead of clone, ? operator
fn find_admin(users: &[User]) -> Option<&User> {
    users.iter().find(|u| u.role == Role::Admin)
}
```

```rust
// BEFORE — unwrap() on I/O, no error context
fn read_config(path: &str) -> Config {
    let content = fs::read_to_string(path).unwrap();
    serde_json::from_str(&content).unwrap()
}

// AFTER — ? propagation, anyhow for error context
fn read_config(path: &str) -> anyhow::Result<Config> {
    let content = fs::read_to_string(path)
        .with_context(|| format!("reading config from {path}"))?;
    let config = serde_json::from_str(&content)
        .context("parsing config JSON")?;
    Ok(config)
}
```

### Common Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `.unwrap()` on `Result`/`Option` in library code | Propagate with `?` or handle explicitly |
| `.clone()` to satisfy borrow checker | Restructure to borrow or use `Rc`/`Arc` if shared ownership is needed |
| `unsafe` without a `// SAFETY:` comment | Add justification; minimize unsafe scope |
| Manual `for i in 0..vec.len()` | `vec.iter()` / `vec.iter().enumerate()` |
| `Box<dyn Error>` in public API | Concrete error type or `thiserror`-derived enum |
| Matching `_` on an enum with a catch-all | Name the variants explicitly for exhaustiveness |

### Code Review Red Flags

- `unwrap()` in library code — panics in a library crash the calling application; use `?` or return `Option`/`Result`
- `clone()` at the start of a function to avoid borrow issues — usually signals a design problem; restructure ownership or use references
- `unsafe` block without a `// SAFETY:` comment explaining the invariants — reviewers cannot verify correctness; the comment is mandatory
- Returning `Box<dyn Error>` from public API functions — forces callers to downcast; use a concrete error type or `thiserror` enum
- Large `impl` blocks mixing business logic with `Display`/`Debug` implementations — split into separate `impl` blocks by concern
- Ignoring `#[must_use]` on `Result` return values — the compiler warns; suppressing with `let _ = ...` hides bugs

---

## C++

### Idiomatic Patterns

- **RAII** (Resource Acquisition Is Initialization) — tie resource lifetime to object lifetime; destructors release resources automatically
- **Smart pointers** — `std::unique_ptr` for single ownership, `std::shared_ptr` for shared ownership; raw `new`/`delete` only inside RAII wrappers
- **`const` correctness** — mark parameters, references, and member functions `const` wherever possible; prevents accidental mutation
- **Range-based `for`** — `for (const auto& item : collection)` over index loops
- **`auto`** — deduce type from initializer for complex or template types; do not overuse for simple types where the type is informative
- **Move semantics** — `std::move` for transferring ownership of large objects; avoids deep copies

```cpp
// BEFORE — raw new/delete, C-style cast, printf, no const
char* buffer = new char[1024];
int* p = (int*)malloc(sizeof(int));
printf("value: %d\n", *p);
delete[] buffer;
free(p);

// AFTER — RAII, smart pointer, const, std::cout
auto buffer = std::make_unique<std::array<char, 1024>>();
auto value = std::make_unique<int>(42);
std::cout << "value: " << *value << '\n';
// buffer and value are freed automatically at scope exit
```

### Common Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `new T` / `delete` | `std::make_unique<T>()` / `std::make_shared<T>()` |
| C-style cast `(Type)expr` | `static_cast<Type>`, `dynamic_cast`, `reinterpret_cast` (named casts) |
| `void*` for generic data | Templates or `std::any` / `std::variant` |
| `printf` / `sprintf` | `std::cout`, `std::format` (C++20), or `fmt::format` |
| Manual memory management | RAII wrappers or standard containers |
| Passing large objects by value | Pass by `const&`; return by value with move semantics |

### Code Review Red Flags

- Raw `new` or `delete` outside of a RAII wrapper — ownership is unclear; use smart pointers or standard containers
- C-style casts `(Type)expr` — bypass const-correctness and static type checking; use named casts to make intent explicit and enable compiler diagnostics
- `void*` for generic storage — erases type information; prefer templates, `std::variant`, or `std::any`
- Missing `const` on member functions that do not modify state — breaks `const`-correctness for users holding `const` references
- `printf`/`sprintf` for string formatting — no type safety; `sprintf` buffer overflows are a common vulnerability; use `std::format` or stream operators
- `std::shared_ptr` used where `std::unique_ptr` suffices — shared ownership has reference-counting overhead and can create cycles; prefer unique ownership

---

## Cross-Language Anti-Pattern Summary

| Anti-Pattern | Languages | Root Cause |
|-------------|-----------|-----------|
| Null / absent value as return signal | Java, TypeScript, C++ | Missing `Optional`/`Option`/`std::optional` |
| Exception / panic for control flow | Go, Rust, C++ | Error returns and `Result` types are the correct mechanism |
| Mutable default argument | Python | Default evaluated once at definition time |
| Unchecked casts / type erasure | Java, C++, TypeScript (`any`) | Generic types or pattern matching prevent runtime surprises |
| Manual resource cleanup | C++, Java, Python | RAII / `with` / try-with-resources handle cleanup safely |
| Defensive cloning to avoid sharing | Rust, Java | Redesign ownership; clone is a code smell, not a fix |

---

## Cross-References

- `refactor-functional-patterns` — Immutability and higher-order function patterns: complements TypeScript array methods, Python comprehensions, Java streams, and Rust iterators
- `review-solid-clean-code` — Single Responsibility and Interface Segregation: Go's small interfaces and Java's records are direct applications of these principles
- `detect-code-smells` — "Primitive Obsession" and "Data Clumps": Python dataclasses, Java records, and Rust structs are the idiomatic cure
- `error-handling-patterns` — Comprehensive error handling strategies: Go error returns, Rust `Result` chaining, and Java `Optional` all implement the patterns described there
