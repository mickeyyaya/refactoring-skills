---
name: type-system-patterns
description: Use when reviewing code for type system quality — covers Discriminated Unions, Phantom Types, Branded/Nominal Types, Generic Constraints, Type Narrowing, Immutable Types, Newtype Pattern, Result/Option Types, Builder Pattern with Types, and Conditional Types with red flags and anti-patterns across TypeScript, Java, Rust, Python, and Go
---

# Type System Patterns for Code Review

## Overview

A strong type system is the first line of defense against bugs. When used well, types make illegal states unrepresentable — the compiler catches entire classes of errors before any test runs.

## When to Use

- APIs accepting raw strings where a typed value is expected
- Functions returning `null`/`undefined` or throwing where a Result type belongs
- Codebases with frequent `any` casts or type assertions
- State machines implemented as ad-hoc string/boolean flags
- Runtime validation that could be moved to compile time

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Discriminated Unions | Tag each variant; switch exhaustively | `instanceof` chains, stringly-typed variants |
| Phantom Types | Compile-time info with no runtime cost | Mixing validated/unvalidated data of same shape |
| Branded/Nominal Types | Structurally identical types made distinct | Passing `userId` where `orderId` required |
| Generic Constraints | Bound type params to enforce contracts | `any` escape hatches, unconstrained generics |
| Type Narrowing / Guards | Runtime checks informing the type system | Unsafe `as` casts, `as unknown as T` |
| Immutable Types | `readonly` and `const` at the type level | Mutable types on value objects and DTOs |
| Newtype Pattern | Wrap primitives for semantic safety | Raw strings for emails, IDs, URLs |
| Result / Option Types | Type-safe absence and error handling | `null` returns, exception-based control flow |
| Builder with Types | Compile-time required-field enforcement | Runtime errors from incomplete builders |
| Conditional Types | Type-level computation and inference | Untyped overloads, duplicated type logic |

---

## Patterns in Detail

### 1. Discriminated Unions / Tagged Unions

Represent a fixed set of mutually exclusive variants with a literal discriminant tag. Compiler enforces exhaustive handling and narrows types per branch.

**Red Flags:** `instanceof` chains or parallel boolean flags allowing impossible combinations; `type`/`status` typed as `string` instead of literal union; switch with no exhaustiveness guard.

```typescript
// BEFORE: invalid state possible (isLoading && isError both true)
interface FetchState { isLoading: boolean; isError: boolean; data: User | null; }

// AFTER: impossible states unrepresentable
type FetchState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'success'; data: User }
  | { status: 'error';   error: string };

function render(state: FetchState): string {
  switch (state.status) {
    case 'success': return state.data.name;
    case 'error':   return state.error;
    default: {
      const _exhaustive: never = state;  // compile error if case missing
      throw new Error(`Unhandled: ${JSON.stringify(_exhaustive)}`);
    }
  }
}
```

**Rust** — use `enum`; **Java 17+** — `sealed interface` with `record` implementations.

---

### 2. Phantom Types

Attach compile-time information with no runtime representation. Tracks validation state without runtime overhead.

**Red Flags:** validated and unvalidated forms share same type; validation documented in comments instead of enforced by compiler.

```typescript
type Validated<T, Brand> = T & { readonly _brand: Brand };
type RawEmail  = string;
type SafeEmail = Validated<string, 'SafeEmail'>;

function validateEmail(raw: RawEmail): SafeEmail | null {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw) ? (raw as SafeEmail) : null;
}

function sendWelcome(email: SafeEmail): void { /* raw strings rejected */ }
```

**Rust** — zero-cost `struct Validated<T>(T)` wrapper with construction limited to a validate function.

---

### 3. Branded / Nominal Types

Make structurally identical primitives distinct so the compiler rejects misuse.

**Red Flags:** `userId`, `orderId`, `productId` all typed as `number`/`string`; arguments silently swappable; monetary amounts of different currencies typed identically.

```typescript
type UserId  = number & { readonly _brand: 'UserId' };
type OrderId = number & { readonly _brand: 'OrderId' };
type USD     = number & { readonly _brand: 'USD' };

function getOrder(userId: UserId, orderId: OrderId): Order { /* ... */ }
// getOrder(orderId, userId) → compile error
```

**Go** — `type UserID int64` creates distinct types. **Python** — `UserId = NewType('UserId', int)` catches misuse with mypy.

---

### 4. Generic Constraints

Bound type parameters to express required capabilities. Eliminates `any` casts inside generics.

**Red Flags:** unconstrained `T` cast to concrete type inside body; `any` where a constrained generic works; copy-pasted code for `string`/`number` variants.

```typescript
// BEFORE
function findById(items: any[], id: any): any { return items.find(i => i.id === id); }

// AFTER
interface Identifiable<Id> { id: Id; }

function findById<Id, T extends Identifiable<Id>>(
  items: readonly T[], id: Id
): T | undefined {
  return items.find(item => item.id === id);
}
```

**Rust** — `fn log_all<T: Display>(items: &[T])`. **Java** — `<T extends Comparable<T>> T max(List<T>)`.

---

### 5. Type Narrowing / Type Guards

Runtime checks the type system understands to narrow a broad type. Prefer named guards over bare `as` casts.

**Red Flags:** `value as SpecificType` with no runtime check; `as unknown as T` (double assertion); inline `typeof`/`instanceof` duplicated across call sites.

```typescript
// BEFORE — throws at runtime if shape wrong
function process(value: unknown): string { return (value as { name: string }).name; }

// AFTER — compiler-understood guard
interface Named { name: string; }

function isNamed(value: unknown): value is Named {
  return typeof value === 'object' && value !== null &&
    'name' in value && typeof (value as Named).name === 'string';
}

function process(value: unknown): string {
  if (!isNamed(value)) throw new Error(`Expected Named: ${JSON.stringify(value)}`);
  return value.name;  // typed Named — no cast
}
```

**Python 3.10+** — `TypeGuard[T]` return annotation on a predicate function.

---

### 6. Immutable Types

Express at the type level that a value must not be modified after construction.

**Red Flags:** mutable interfaces for value objects, DTOs, or config; arrays typed as `T[]` passed into functions that must not mutate; shared config without `readonly`.

```typescript
// BEFORE — nothing prevents mutation
interface Config { apiUrl: string; timeout: number; }

// AFTER
type Config = Readonly<{ apiUrl: string; timeout: number; }>;

// Deep readonly for nested structures
type DeepReadonly<T> = { readonly [K in keyof T]: DeepReadonly<T[K]> };
```

**Rust** — immutable by default; mutation requires explicit `mut`.

Cross-reference: `refactor-organizing-data` — "Encapsulate Field" controls value construction and change.

---

### 7. Newtype Pattern

Wrap a primitive in a named type for semantic safety. Incompatible with the raw primitive.

**Red Flags:** raw `string` for email/URL/token; raw `number` for money/percentage/units; validation logic copy-pasted wherever the primitive appears.

```typescript
class Email {
  private constructor(readonly value: string) {}
  static parse(raw: string): Email {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw)) throw new Error(`Invalid email: ${raw}`);
    return new Email(raw);
  }
}

function sendEmail(to: Email): void { /* raw strings rejected */ }
```

**Rust** — `struct Email(String)` with `parse` constructor. **Go** — `type Email string` with `ParseEmail` factory.

---

### 8. Result / Option Types

Represent success/failure and presence/absence as first-class types. Forces callers to handle both cases.

**Red Flags:** `T | null` for error cases (not just absence); `try/catch` for control flow; ignorable error objects without compiler enforcement.

```typescript
type Result<T, E = string> =
  | { readonly ok: true;  readonly value: T }
  | { readonly ok: false; readonly error: E };

function parsePositive(raw: string): Result<number> {
  const n = Number(raw);
  if (isNaN(n)) return { ok: false, error: `Not a number: ${raw}` };
  if (n <= 0)   return { ok: false, error: `Must be positive: ${n}` };
  return { ok: true, value: n };
}

const result = parsePositive(input);
if (result.ok) console.log(result.value);
else           console.error(result.error);
```

**Rust** — `Result<T, E>` and `Option<T>` built-in; `.unwrap()` is a red flag in production.

Cross-reference: `refactor-functional-patterns` — Functors/Monads covers chaining Results with `map`/`flatMap`.

---

### 9. Builder Pattern with Types

Use the type system to enforce all required fields are set before `build()` is callable. Moves completeness validation from runtime to compile time.

**Red Flags:** `build()` throws at runtime for missing fields; required and optional fields indistinguishable in builder type; tests needed for missing-field errors (should be compile errors).

```typescript
class UserBuilder<State extends object = object> {
  private constructor(private readonly state: State) {}
  static create(): UserBuilder { return new UserBuilder({}); }

  withName(name: string): UserBuilder<State & { name: string }> {
    return new UserBuilder({ ...this.state, name });
  }
  withEmail(email: string): UserBuilder<State & { email: string }> {
    return new UserBuilder({ ...this.state, email });
  }
}

// build() only exists when all required fields present
interface UserBuilder<State extends { name: string; email: string }> {
  build(): User;
}

UserBuilder.create().withName('Alice').withEmail('a@b.com').build();  // OK
UserBuilder.create().withName('Alice').build();  // compile error
```

---

### 10. Conditional Types / Type-Level Programming

Compute types from other types using conditional logic for precise return types and eliminating duplicated type info.

**Red Flags:** `any` return type when actual return depends on input type; identical-body overloads with slightly different signatures; type logic duplicated across files.

```typescript
type Awaited<T> = T extends Promise<infer U> ? Awaited<U> : T;

type ElementOf<T> = T extends readonly (infer U)[] ? U : never;

type A = ElementOf<string[]>;   // string
type B = ElementOf<number[][]>; // number[]
```

**Use sparingly.** Prefer discriminated unions and generic constraints for most problems. Reserve for library-level abstractions where precision justifies complexity.

---

## Type System Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| **`any` / `Object` abuse** | Replace with `unknown` (forces narrowing), proper interface, or generic constraint |
| **Type assertion overuse** (`as SomeType`) | Add runtime type guard; reserve `as` for already-narrowed values |
| **Stringly-typed APIs** | Replace with discriminated union or string literal union |
| **Primitive obsession** | Apply Branded Types or Newtype per semantic domain |
| **Overly complex generics** (5+ type params) | Extract intermediate aliases; split into simpler overloads |
| **Parallel boolean flags** | Replace with Discriminated Union |

**Stringly-typed API example:**
```typescript
// WRONG
function setRole(userId: string, role: string): void { /* ... */ }
setRole(userId, 'adnimistrator');  // typo compiles silently

// CORRECT
type Role = 'admin' | 'editor' | 'viewer';
function setRole(userId: UserId, role: Role): void { /* ... */ }
```

---

## Cross-References

- `refactor-organizing-data` — "Replace Data Value with Object" and "Replace Type Code with Subclasses" introduce Newtype and Discriminated Union patterns
- `language-specific-idioms` — Rust enums, Go type aliases, Python `NewType`, Java sealed classes
- `refactor-functional-patterns` — Immutability and Result/Option types; Functors/Monads for chaining Results
- `detect-code-smells` — "Primitive Obsession" resolves to Branded Types; "Temporary Field" resolves to Discriminated Unions
