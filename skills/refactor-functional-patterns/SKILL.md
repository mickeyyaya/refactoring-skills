---
name: refactor-functional-patterns
description: Use when reviewing code for functional programming quality — covers Pure Functions, Immutability, Map/Filter/Reduce, Function Composition, Higher-Order Functions, Currying, Functors/Monads, and Pattern Matching with red flags and anti-patterns
---

# Refactor: Functional Programming Patterns

## Overview

Functional programming (FP) patterns produce code that is predictable, testable, and composable. These patterns reduce bugs by eliminating shared mutable state and side effects. Use this guide during code review to identify opportunities to apply or enforce FP principles.

## When to Use

- Reviewing code with frequent state mutation bugs
- Functions that are hard to unit test due to hidden dependencies
- Complex data transformation pipelines
- Code with repeated null-check boilerplate
- Functions that do too much (mix computation and I/O)

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Pure Functions | Same input → same output, no side effects | Accessing global state inside business logic |
| Immutability | Never mutate, always create new | `push`, `pop`, or property assignment on existing objects |
| Map/Filter/Reduce | Declarative collection transforms | Manual loops accumulating results |
| Function Composition | Build pipelines from small functions | Deeply nested function calls `f(g(h(x)))` |
| Higher-Order Functions | Functions that take/return functions | Copy-pasted blocks differing by one operation |
| Currying / Partial Application | Fix some arguments, defer the rest | Repeatedly passing the same first argument |
| Functors / Monads | Chainable containers for optional/error values | Nested null checks, try-catch pyramids |
| Pattern Matching | Destructure and branch on data shape | `instanceof` chains or long type-checking conditionals |

---

## Patterns in Detail

### 1. Pure Functions

**Intent:** Same input → same output, no side effects (no I/O, no global writes, no mutations). All business logic should be pure; reserve impure code for system edges (DB, network, UI).

**Code Review Red Flags:**
- Reading from `global`, `process.env`, or module-level variables inside a computation
- `console.log`, file writes, or network calls mixed into business logic
- Parameter mutation: `arr.push(x)` or `obj.field = value` inside a function
- `Date.now()`, `Math.random()`, or `new UUID()` called inside a deterministic function

**TypeScript — Before:**
```typescript
let taxRate = 0.2;  // global

function calculateTotal(price: number): number {
  const total = price * (1 + taxRate);  // reads global state
  console.log(`total: ${total}`);       // side effect
  return total;
}
```

**TypeScript — After:**
```typescript
function calculateTotal(price: number, taxRate: number): number {
  return price * (1 + taxRate);  // pure: only uses arguments
}
```

**Python — After:**
```python
def calculate_total(price: float, tax_rate: float) -> float:
    return price * (1 + tax_rate)
```

---

### 2. Immutability

**Intent:** Never modify existing data structures. Always return new copies. Critical in shared state, React/Redux, and concurrent code.

**Code Review Red Flags:**
- `array.push()`, `array.pop()`, `array.splice()`, `array.sort()` — all mutate in place
- `object.field = value` or `delete object.key`
- `Object.assign(target, source)` where `target` is the original object (not a fresh `{}`)
- Spread that is only one level deep when nested objects also need immutability
- Missing `readonly` on TypeScript interfaces that should not be changed

**TypeScript — Before:**
```typescript
function addItem(cart: CartItem[], item: CartItem): CartItem[] {
  cart.push(item);  // mutates caller's array
  return cart;
}
```

**TypeScript — After:**
```typescript
function addItem(cart: readonly CartItem[], item: CartItem): readonly CartItem[] {
  return [...cart, item];  // new array, original untouched
}
```

**Python — After:**
```python
def add_item(cart: tuple, item) -> tuple:
    return (*cart, item)  # tuples are immutable; returns new tuple
```

Cross-reference: `refactor-composing-methods` — "Remove Assignments to Parameters" enforces the same principle at the parameter level.

---

### 3. Map / Filter / Reduce

**Intent:** Express collection transformations declaratively. Use `map` to transform, `filter` to select, `reduce` to aggregate, `flatMap` to flatten nested results.

**Code Review Red Flags:**
- A `for` loop that builds an accumulator array (`result.push(...)`) → use `map`
- A `for` loop that skips items with `if (condition) result.push(...)` → use `filter`
- A `for` loop that reduces to a single value (`total += item.price`) → use `reduce`
- Nested loops that can be replaced with `flatMap`
- Index variable used only to access the current element (not for position logic)

**TypeScript — Before:**
```typescript
function getActiveUserEmails(users: User[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < users.length; i++) {
    if (users[i].active) {
      result.push(users[i].email.toLowerCase());
    }
  }
  return result;
}
```

**TypeScript — After:**
```typescript
function getActiveUserEmails(users: readonly User[]): readonly string[] {
  return users
    .filter(user => user.active)
    .map(user => user.email.toLowerCase());
}
```

**Python — After:**
```python
def get_active_user_emails(users: list[User]) -> list[str]:
    return [u.email.lower() for u in users if u.active]
```

---

### 4. Function Composition

**Intent:** Build complex transformations by combining small, single-purpose functions into a pipeline. Apply when three or more sequential transforms are applied to a value.

**Code Review Red Flags:**
- Deeply nested calls: `format(validate(parse(trim(input))))`
- Intermediate variables named `temp`, `step1`, `result1`
- A single function doing three distinct things in sequence with comments separating them

**TypeScript — Before:**
```typescript
function processUserInput(raw: string): string {
  const trimmed = raw.trim();
  const lower = trimmed.toLowerCase();
  const normalized = lower.replace(/\s+/g, '_');
  return normalized;
}
```

**TypeScript — After:**
```typescript
const pipe = <T>(...fns: Array<(x: T) => T>) => (x: T): T =>
  fns.reduce((acc, fn) => fn(acc), x);

const processUserInput = pipe(
  (s: string) => s.trim(),
  (s: string) => s.toLowerCase(),
  (s: string) => s.replace(/\s+/g, '_'),
);
```

**Python — After:**
```python
from functools import reduce

def pipe(*fns):
    return lambda x: reduce(lambda acc, f: f(acc), fns, x)

process_user_input = pipe(str.strip, str.lower, lambda s: s.replace(' ', '_'))
```

---

### 5. Higher-Order Functions

**Intent:** Abstract over behavior by passing functions as arguments or returning them as results, eliminating copy-pasted blocks that differ only in one operation.

**Code Review Red Flags:**
- Two functions identical except for one operation (sort comparator, predicate, transform step)
- Callback-style code that could be abstracted into a retry/cache/log wrapper

**TypeScript — Before:**
```typescript
function sortByName(users: User[]): User[] {
  return [...users].sort((a, b) => a.name.localeCompare(b.name));
}
function sortByAge(users: User[]): User[] {
  return [...users].sort((a, b) => a.age - b.age);
}
```

**TypeScript — After:**
```typescript
function sortBy<T>(key: (item: T) => number | string) {
  return (items: readonly T[]): readonly T[] =>
    [...items].sort((a, b) => {
      const ka = key(a), kb = key(b);
      return ka < kb ? -1 : ka > kb ? 1 : 0;
    });
}

const sortByName = sortBy((u: User) => u.name);
const sortByAge  = sortBy((u: User) => u.age);
```

---

### 6. Currying / Partial Application

**Intent:** Pre-fill some arguments to produce a specialized function. Apply when the same function is repeatedly called with the same leading arguments.

**Code Review Red Flags:**
- Repeated calls like `formatDate(locale, date1)`, `formatDate(locale, date2)` — the `locale` should be partially applied
- Config objects passed through every call in a chain when only the last argument varies

**TypeScript — Before:**
```typescript
function formatCurrency(locale: string, currency: string, amount: number): string {
  return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount);
}

// caller repeatedly specifies locale and currency
formatCurrency('en-US', 'USD', 9.99);
formatCurrency('en-US', 'USD', 19.99);
```

**TypeScript — After:**
```typescript
const formatCurrency =
  (locale: string) =>
  (currency: string) =>
  (amount: number): string =>
    new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount);

const formatUSD = formatCurrency('en-US')('USD');
formatUSD(9.99);
formatUSD(19.99);
```

**Python — After:**
```python
from functools import partial

format_usd = partial(format_currency, 'en-US', 'USD')
format_usd(9.99)
```

---

### 7. Functors / Monads (Optional, Result, Promise)

**Intent:** Use chainable containers (`Optional`/`Maybe`, `Result`/`Either`, `Promise`) to sequence operations that may fail or be absent, eliminating null-check pyramids and nested try-catch.

**Code Review Red Flags:**
- `if (a !== null && a.b !== null && a.b.c !== null)` chains
- `try { try { ... } catch {} } catch {}` nesting
- Functions returning `null | undefined | T` without a container type

**TypeScript — Before (null pyramid):**
```typescript
function getCity(user: User | null): string | null {
  if (user !== null) {
    if (user.address !== null) {
      if (user.address.city !== null) {
        return user.address.city.toUpperCase();
      }
    }
  }
  return null;
}
```

**TypeScript — After (optional chaining + nullish coalescing):**
```typescript
function getCity(user: User | null): string | null {
  return user?.address?.city?.toUpperCase() ?? null;
}
```

**TypeScript — After (Result type for error handling):**
```typescript
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };

function parseAge(raw: string): Result<number, string> {
  const n = Number(raw);
  if (isNaN(n) || n < 0) return { ok: false, error: `Invalid age: ${raw}` };
  return { ok: true, value: n };
}

// caller handles both branches explicitly — no hidden exceptions
const result = parseAge(input);
if (result.ok) console.log(result.value);
else console.error(result.error);
```

**Python — After:**
```python
from dataclasses import dataclass

@dataclass(frozen=True)
class Ok:
    value: int

@dataclass(frozen=True)
class Err:
    error: str

def parse_age(raw: str) -> Ok | Err:
    try:
        n = int(raw)
        return Ok(n) if n >= 0 else Err(f"Negative age: {raw}")
    except ValueError:
        return Err(f"Not a number: {raw}")
```

---

### 8. Pattern Matching

**Intent:** Destructure and branch on data shape using discriminated unions instead of `instanceof` chains or type-discriminant conditionals.

**Code Review Red Flags:**
- `if (x instanceof A) ... else if (x instanceof B) ...` — use discriminated unions
- `if (x.type === 'circle') ... else if (x.type === 'rect') ...` without exhaustiveness check
- Switch statements with no `default` (or `default: throw`) when the value is a union

**TypeScript — Before:**
```typescript
function area(shape: Circle | Rectangle | Triangle): number {
  if (shape instanceof Circle) return Math.PI * shape.radius ** 2;
  if (shape instanceof Rectangle) return shape.width * shape.height;
  if (shape instanceof Triangle) return 0.5 * shape.base * shape.height;
  throw new Error('Unknown shape');
}
```

**TypeScript — After (discriminated union with exhaustiveness):**
```typescript
type Shape =
  | { kind: 'circle';    radius: number }
  | { kind: 'rectangle'; width: number; height: number }
  | { kind: 'triangle';  base: number;  height: number };

function area(shape: Shape): number {
  switch (shape.kind) {
    case 'circle':    return Math.PI * shape.radius ** 2;
    case 'rectangle': return shape.width * shape.height;
    case 'triangle':  return 0.5 * shape.base * shape.height;
    default: {
      const _exhaustive: never = shape;  // compile error if case is missing
      throw new Error(`Unhandled shape: ${JSON.stringify(_exhaustive)}`);
    }
  }
}
```

**Python — After (Python 3.10+ match):**
```python
def area(shape: dict) -> float:
    match shape:
        case {'kind': 'circle', 'radius': r}:    return 3.14159 * r ** 2
        case {'kind': 'rectangle', 'width': w, 'height': h}: return w * h
        case {'kind': 'triangle', 'base': b, 'height': h}:  return 0.5 * b * h
        case _: raise ValueError(f"Unknown shape: {shape}")
```

---

## FP Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Impure function masquerading as pure** | Function looks pure but reads a closure variable that changes over time | Make the mutable dependency an explicit parameter |
| **Shallow-copy illusion** | `{...obj}` or `[...arr]` creates a new reference but nested objects are still shared | Deep-clone nested structures or use immutable data libraries (Immer, Immutable.js) |
| **Point-free everything** | Removing all named parameters for brevity makes code unreadable | Use point-free style only when it clarifies, not as a rule |
| **Monadic overkill** | Wrapping a simple `if (!x) return null` in a full Maybe monad | Match the tool to the complexity — prefer optional chaining for shallow checks |
| **Impure reduce** | Using `reduce` with an accumulator that is mutated inside the callback | Return a new accumulator object each iteration |
| **Accidental shared state in curried functions** | A curried function captures a mutable value from outer scope | Ensure captured values are constants or primitives |

**Shallow-copy illusion — example:**
```typescript
// WRONG — nested address object is still shared
const updated = { ...user, name: 'Alice' };
updated.address.city = 'Boston';  // mutates original user.address!

// CORRECT — spread nested objects too, or use structuredClone
const updated = { ...user, name: 'Alice', address: { ...user.address, city: 'Boston' } };
```

---

## Cross-References

- `refactor-composing-methods` — "Remove Assignments to Parameters" for immutability at the argument level; "Substitute Algorithm" for replacing loops with declarative transforms
- `refactor-simplifying-conditionals` — Simplifying the `if`/`else` chains that pattern matching replaces
- `review-solid-clean-code` — Single Responsibility Principle aligns with pure functions; Open/Closed Principle aligns with HOFs
- `detect-code-smells` — "Data Clumps" often signal missing algebraic data types; "Long Method" often signals missing function composition
