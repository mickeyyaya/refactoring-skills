---
name: refactor-functional-patterns
description: Use when reviewing code for functional programming quality — covers Pure Functions, Immutability, Map/Filter/Reduce, Function Composition, Higher-Order Functions, Currying, Functors/Monads, and Pattern Matching with red flags and anti-patterns
---

# Refactor: Functional Programming Patterns

## Overview

FP patterns produce code that is predictable, testable, and composable by eliminating shared mutable state and side effects.

**When to use:** State mutation bugs, hidden dependencies, untestable functions, complex data pipelines, repeated null-check boilerplate, functions mixing computation and I/O.

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

**Red Flags:** Reading `global`/`process.env` in computation; I/O mixed into business logic; parameter mutation (`arr.push(x)`); `Date.now()`/`Math.random()` in deterministic functions.

```typescript
// BEFORE — reads global state + side effect
let taxRate = 0.2;
function calculateTotal(price: number): number {
  const total = price * (1 + taxRate);
  console.log(`total: ${total}`);
  return total;
}

// AFTER — pure: only uses arguments
function calculateTotal(price: number, taxRate: number): number {
  return price * (1 + taxRate);
}
```

```python
# Python equivalent
def calculate_total(price: float, tax_rate: float) -> float:
    return price * (1 + tax_rate)
```

---

### 2. Immutability

**Red Flags:** `.push()`/`.pop()`/`.splice()`/`.sort()` mutate in place; `object.field = value`; `Object.assign` on original; shallow spread missing nested immutability; missing `readonly`.

```typescript
// BEFORE — mutates caller's array
function addItem(cart: CartItem[], item: CartItem): CartItem[] {
  cart.push(item);
  return cart;
}

// AFTER — new array, original untouched
function addItem(cart: readonly CartItem[], item: CartItem): readonly CartItem[] {
  return [...cart, item];
}
```

```python
# Python — tuples are immutable
def add_item(cart: tuple, item) -> tuple:
    return (*cart, item)
```

Cross-reference: `refactor-composing-methods` — "Remove Assignments to Parameters".

---

### 3. Map / Filter / Reduce

**Red Flags:** Loop building accumulator → `map`; with condition → `filter`; single value → `reduce`; nested loops → `flatMap`; index used only to access element.

```typescript
// BEFORE
function getActiveUserEmails(users: User[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < users.length; i++) {
    if (users[i].active) result.push(users[i].email.toLowerCase());
  }
  return result;
}

// AFTER
function getActiveUserEmails(users: readonly User[]): readonly string[] {
  return users.filter(u => u.active).map(u => u.email.toLowerCase());
}
```

```python
# Python — list comprehension
def get_active_user_emails(users: list[User]) -> list[str]:
    return [u.email.lower() for u in users if u.active]
```

---

### 4. Function Composition

**Red Flags:** Nested calls `f(g(h(x)))`; variables named `temp`/`step1`/`result1`; single function doing three things separated by comments.

```typescript
// BEFORE
function processUserInput(raw: string): string {
  const trimmed = raw.trim();
  const lower = trimmed.toLowerCase();
  return lower.replace(/\s+/g, '_');
}

// AFTER — pipeline
const pipe = <T>(...fns: Array<(x: T) => T>) => (x: T): T =>
  fns.reduce((acc, fn) => fn(acc), x);

const processUserInput = pipe(
  (s: string) => s.trim(),
  (s: string) => s.toLowerCase(),
  (s: string) => s.replace(/\s+/g, '_'),
);
```

```python
from functools import reduce
def pipe(*fns):
    return lambda x: reduce(lambda acc, f: f(acc), fns, x)

process_user_input = pipe(str.strip, str.lower, lambda s: s.replace(' ', '_'))
```

---

### 5. Higher-Order Functions

**Red Flags:** Two functions identical except one operation; callback code abstractable into retry/cache/log wrapper.

```typescript
// BEFORE — duplicated sort logic
function sortByName(users: User[]): User[] {
  return [...users].sort((a, b) => a.name.localeCompare(b.name));
}
function sortByAge(users: User[]): User[] {
  return [...users].sort((a, b) => a.age - b.age);
}

// AFTER — parameterized
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

**Red Flags:** Repeated calls like `formatDate(locale, date1)`, `formatDate(locale, date2)`; config objects threaded when only the last arg varies.

```typescript
// BEFORE — caller repeatedly specifies locale and currency
formatCurrency('en-US', 'USD', 9.99);
formatCurrency('en-US', 'USD', 19.99);

// AFTER — curried
const formatCurrency =
  (locale: string) => (currency: string) => (amount: number): string =>
    new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount);

const formatUSD = formatCurrency('en-US')('USD');
formatUSD(9.99);
formatUSD(19.99);
```

```python
from functools import partial
format_usd = partial(format_currency, 'en-US', 'USD')
format_usd(9.99)
```

---

### 7. Functors / Monads (Optional, Result, Promise)

**Red Flags:** `if (a !== null && a.b !== null && ...)` chains; nested try-catch; functions returning `null | undefined | T` without a container type.

```typescript
// BEFORE — null pyramid
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

// AFTER — optional chaining
function getCity(user: User | null): string | null {
  return user?.address?.city?.toUpperCase() ?? null;
}
```

```typescript
// Result type for error handling
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E };

function parseAge(raw: string): Result<number, string> {
  const n = Number(raw);
  if (isNaN(n) || n < 0) return { ok: false, error: `Invalid age: ${raw}` };
  return { ok: true, value: n };
}
```

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

**Red Flags:** `instanceof` chains — use discriminated unions; type conditionals without exhaustiveness check; switch on union with no `default`.

```typescript
// BEFORE — instanceof chain
function area(shape: Circle | Rectangle | Triangle): number {
  if (shape instanceof Circle) return Math.PI * shape.radius ** 2;
  if (shape instanceof Rectangle) return shape.width * shape.height;
  if (shape instanceof Triangle) return 0.5 * shape.base * shape.height;
  throw new Error('Unknown shape');
}

// AFTER — discriminated union with exhaustiveness
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
      const _exhaustive: never = shape;
      throw new Error(`Unhandled shape: ${JSON.stringify(_exhaustive)}`);
    }
  }
}
```

```python
# Python 3.10+
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
| **Impure function masquerading as pure** | Reads a closure variable that changes over time | Make mutable dependency an explicit parameter |
| **Shallow-copy illusion** | `{...obj}` — nested objects still shared | Deep-clone or use Immer/Immutable.js |
| **Point-free everything** | Removing all named parameters hurts readability | Use point-free only when it clarifies |
| **Monadic overkill** | Full Maybe monad for simple null check | Prefer optional chaining for shallow checks |
| **Impure reduce** | Accumulator mutated inside callback | Return new accumulator each iteration |
| **Shared state in curried functions** | Captures mutable outer scope value | Ensure captured values are constants |

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

- `refactor-composing-methods` — "Remove Assignments to Parameters" (immutability); "Substitute Algorithm" (loops → declarative)
- `refactor-simplifying-conditionals` — Simplifying `if`/`else` chains that pattern matching replaces
- `review-solid-clean-code` — SRP aligns with pure functions; OCP aligns with HOFs
- `detect-code-smells` — "Data Clumps" → missing algebraic data types; "Long Method" → missing composition
