---
name: language-specific-idioms
description: Use when reviewing code for language-specific correctness — covers idiomatic patterns, common anti-idioms, and code review red flags for TypeScript/JavaScript, Python, Java, Go, Rust, and C++, with before/after examples and a quick reference table
---

# Language-Specific Idioms for Code Review

## Overview

Every language has a "grain" — idiomatic patterns aligned with its type system, memory model, and stdlib. Code fighting the grain is harder to read, error-prone, and often slower.

**When to use:** Reviewing PRs where authors may not know the language idioms, onboarding contributors, or cross-language teams.

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

- Destructuring + optional chaining (`?.`) + nullish coalescing (`??`)
- Array methods over loops; `async`/`await` over raw Promises
- `readonly`/`as const` for immutability; `const`/`let` only (never `var`)

```typescript
// BEFORE — verbose, var-scoped, manual null check
function getCity(user) {
  var city = null;
  if (user && user.address && user.address.city) { city = user.address.city; }
  return city || 'Unknown';
}

// AFTER — destructuring + optional chaining + nullish coalescing
function getCity({ address }: User): string {
  return address?.city ?? 'Unknown';
}
```

### Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `var x` | `const x` or `let x` |
| `param: any` | Specific type, union, or generic |
| `a == b` | `a === b` |
| `Foo.prototype.bar = ...` | `class Foo { bar() {} }` |
| `new Promise(...)` wrapping async | `async function` directly |
| `arr.forEach(async ...)` | `await Promise.all(arr.map(async ...))` |

### Red Flags

- `any` in signatures disables type checking; `await` inside `forEach` swallows errors
- Callback async in `async` functions without promisification; missing `readonly` across modules

---

## Python

### Idiomatic Patterns

- Comprehensions over loops; context managers (`with`) for resources; generators for lazy sequences
- f-strings over `%`/`.format()`; `dataclasses`/`NamedTuple`; type hints for `mypy`
- `enumerate()` for index+value; `zip()` for parallel iteration

```python
# BEFORE — C-style loop, no type hints
def get_names(users):
    names = []
    for i in range(len(users)):
        names.append(users[i]['name'].upper())
    return names

# AFTER — comprehension + type hints
def get_names(users: list[dict[str, str]]) -> list[str]:
    return [user['name'].upper() for user in users]
```

```python
# BEFORE — mutable default, bare except, manual close
def read_lines(path, result=[]):
    try:
        f = open(path); result.extend(f.readlines()); f.close()
    except:
        pass
    return result

# AFTER
def read_lines(path: str, result: list[str] | None = None) -> list[str]:
    output = result if result is not None else []
    try:
        with open(path, encoding='utf-8') as f:
            output.extend(f.readlines())
    except OSError as exc:
        raise RuntimeError(f"Failed to read {path}") from exc
    return output
```

### Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `for i in range(len(xs)): xs[i]` | `for x in xs:` or `enumerate(xs)` |
| `def fn(items=[])` | `def fn(items: list \| None = None)` |
| `except:` bare | `except SpecificError as e:` |
| `"Hello " + name` | `f"Hello {name}"` |
| `isinstance(x, A) or isinstance(x, B)` | `isinstance(x, (A, B))` or `match x:` |
| `x.keys()` iteration | `for key in x:` |

### Red Flags

- Mutable default arg — evaluated once, shared across calls; bare `except:` catches `SystemExit`
- Missing type hints on public functions; class with only `__init__` — use `@dataclass`

---

## Java

### Idiomatic Patterns

- `Optional<T>` for nullable returns; streams over loops; records for immutable data
- Sealed classes for exhaustive hierarchies; try-with-resources; `var` (10+); `@Override` always

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

// AFTER — typed generics, stream
public List<User> getActiveUsers(List<User> users) {
    return users.stream()
        .filter(User::isActive)
        .collect(Collectors.toUnmodifiableList());
}
```

### Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| Returning `null` | `Optional<T>` or domain exception |
| Raw types `List`, `Map` | `List<T>`, `Map<K,V>` |
| `str1 == str2` | `str1.equals(str2)` |
| Checked exceptions for unrecoverable errors | `RuntimeException` subclass |
| Mutable beans with setters | Records or immutable value objects |

### Red Flags

- `null` return forces every caller to null-check; raw types disable compile-time checking
- `==` on non-primitives compares references; checked exceptions wrapping I/O in business logic
- Missing `@Override` — renamed superclass method silently breaks

---

## Go

### Idiomatic Patterns

- `(T, error)` returns handled immediately; implicit small interfaces at point of use
- Goroutines + channels; `defer` for cleanup; `:=` for short declarations; table-driven tests

```go
// BEFORE — panic, naked return
func divide(a, b float64) (result float64) {
    if b == 0 { panic("division by zero") }
    result = a / b; return
}

// AFTER — explicit error return
func divide(a, b float64) (float64, error) {
    if b == 0 { return 0, fmt.Errorf("divide: divisor must be non-zero") }
    return a / b, nil
}
```

### Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `panic` for expected errors | Return `(T, error)` |
| Large `init()` | Explicit constructors |
| Fat interfaces (5+ methods) | Single-method interfaces |
| Naked returns in long functions | Explicit return values |
| `errors.New(fmt.Sprintf(...))` | `fmt.Errorf("ctx: %w", err)` |
| Goroutine without lifecycle | `context.Context` or `errgroup` |

### Red Flags

- `panic` in library code crashes entire program; `init()` with side effects breaks testing
- Interface 5+ methods in producer — move to consumer; goroutine without stop signal leaks
- Missing `defer mu.Unlock()` after `mu.Lock()`

---

## Rust

### Idiomatic Patterns

- Ownership/borrowing (`&T`/`&mut T`) over cloning; `Result`/`Option` with `?` propagation
- Exhaustive `match`; `if let`/`while let` for single-variant; iterators compose lazily
- Derive macros for value types; explicit lifetimes when needed

```rust
// BEFORE — unwrap(), unnecessary clone, manual loop
fn find_admin(users: Vec<User>) -> Option<User> {
    let users_clone = users.clone();
    for i in 0..users_clone.len() {
        if users_clone[i].role == Role::Admin {
            return Some(users_clone[i].clone());
        }
    }
    None
}

// AFTER — iterator, borrow instead of clone
fn find_admin(users: &[User]) -> Option<&User> {
    users.iter().find(|u| u.role == Role::Admin)
}
```

```rust
// BEFORE — unwrap() on I/O, no context
fn read_config(path: &str) -> Config {
    let content = fs::read_to_string(path).unwrap();
    serde_json::from_str(&content).unwrap()
}

// AFTER — ? with anyhow context
fn read_config(path: &str) -> anyhow::Result<Config> {
    let content = fs::read_to_string(path).with_context(|| format!("reading {path}"))?;
    Ok(serde_json::from_str(&content).context("parsing config JSON")?)
}
```

### Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `.unwrap()` in library code | `?` or explicit handling |
| `.clone()` to satisfy borrow checker | Restructure or `Rc`/`Arc` |
| `unsafe` without `// SAFETY:` | Add justification; minimize scope |
| `for i in 0..vec.len()` | `vec.iter().enumerate()` |
| `Box<dyn Error>` in public API | `thiserror` enum |
| `_` catch-all on enum | Name variants for exhaustiveness |

### Red Flags

- `unwrap()` in library code panics the caller; `clone()` to avoid borrows signals design issue
- `unsafe` without `// SAFETY:` is unverifiable; `Box<dyn Error>` in public APIs forces downcast
- `let _ = ...` on `#[must_use]` `Result` hides bugs

---

## C++

### Idiomatic Patterns

- RAII ties resource to object lifetime; `unique_ptr`/`shared_ptr` (raw `new`/`delete` only inside RAII)
- `const` correctness everywhere; range-based `for`; `auto` for complex types; move semantics

```cpp
// BEFORE — raw new/delete, C-style cast, printf
char* buffer = new char[1024];
int* p = (int*)malloc(sizeof(int));
printf("value: %d\n", *p);
delete[] buffer;
free(p);

// AFTER — RAII, smart pointer, std::cout
auto buffer = std::make_unique<std::array<char, 1024>>();
auto value = std::make_unique<int>(42);
std::cout << "value: " << *value << '\n';
// freed automatically at scope exit
```

### Anti-Idioms

| Anti-Idiom | Idiomatic Replacement |
|------------|----------------------|
| `new T` / `delete` | `make_unique<T>()` / `make_shared<T>()` |
| C-style cast `(Type)expr` | `static_cast`, `dynamic_cast`, `reinterpret_cast` |
| `void*` | Templates, `std::any`, `std::variant` |
| `printf` / `sprintf` | `std::format` (C++20) or `fmt::format` |
| Manual memory management | RAII wrappers or containers |
| Large objects by value | `const&`; return by value with move |

### Red Flags

- Raw `new`/`delete` outside RAII — unclear ownership; C-style casts bypass const-correctness
- `void*` erases type info; missing `const` on non-mutating members
- `printf`/`sprintf` — no type safety, buffer overflow; `shared_ptr` where `unique_ptr` suffices

---

## Cross-Language Anti-Pattern Summary

| Anti-Pattern | Languages | Root Cause |
|-------------|-----------|-----------|
| Null as return signal | Java, TypeScript, C++ | Missing `Optional`/`Option`/`std::optional` |
| Exception/panic for control flow | Go, Rust, C++ | Error returns and `Result` types are correct |
| Mutable default argument | Python | Default evaluated once at definition time |
| Unchecked casts / type erasure | Java, C++, TypeScript (`any`) | Generics or pattern matching prevent surprises |
| Manual resource cleanup | C++, Java, Python | RAII / `with` / try-with-resources |
| Defensive cloning | Rust, Java | Redesign ownership; clone is a smell |

---

## Cross-References

- `refactor-functional-patterns` — Immutability and HOF patterns complement array methods, comprehensions, streams, iterators
- `review-solid-clean-code` — SRP/ISP: Go's small interfaces and Java's records
- `detect-code-smells` — "Primitive Obsession"/"Data Clumps": dataclasses, records, structs are the cure
- `error-handling-patterns` — Go error returns, Rust `Result`, Java `Optional`
