---
name: type-system-patterns
description: Use when reviewing code for type system quality — covers Discriminated Unions, Phantom Types, Branded/Nominal Types, Generic Constraints, Type Narrowing, Immutable Types, Newtype Pattern, Result/Option Types, Builder Pattern with Types, and Conditional Types with red flags and anti-patterns across TypeScript, Java, Rust, Python, and Go
---

# Type System Patterns for Code Review

## Overview

A strong type system is the first line of defense against bugs. When used well, types make illegal states unrepresentable — the compiler catches entire classes of errors before any test runs. Use this guide during code review to identify missing type safety, overly permissive signatures, and opportunities to encode invariants at the type level.

## When to Use

- APIs that accept raw strings where a typed value is expected
- Functions returning `null`, `undefined`, or throwing where a Result type belongs
- Codebases with frequent `any` casts or type assertions
- State machines implemented as ad-hoc string/boolean flags
- Runtime validation that could be moved to compile time

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Discriminated Unions | Tag each variant; switch exhaustively | `instanceof` chains, stringly-typed variants |
| Phantom Types | Compile-time info with no runtime cost | Mixing validated/unvalidated data of the same shape |
| Branded/Nominal Types | Make structurally identical types distinct | Passing `userId` where `orderId` is required |
| Generic Constraints | Bound type parameters to enforce contracts | `any` escape hatches, unconstrained generics |
| Type Narrowing / Guards | Runtime checks that inform the type system | Unsafe `as` casts, `as unknown as T` |
| Immutable Types | `readonly` and `const` at the type level | Mutable types on value objects and DTOs |
| Newtype Pattern | Wrap primitives for semantic safety | Raw strings for emails, IDs, URLs |
| Result / Option Types | Type-safe absence and error handling | `null` returns, exception-based control flow |
| Builder with Types | Compile-time required-field enforcement | Runtime errors from incomplete builders |
| Conditional Types | Type-level computation and inference | Untyped overloads, duplicated type logic |

---

## Patterns in Detail

### 1. Discriminated Unions / Tagged Unions

**Intent:** Represent a fixed set of mutually exclusive variants with a literal discriminant tag. The compiler enforces exhaustive handling and narrows types automatically per branch.

**Code Review Red Flags:**
- `instanceof` chains or parallel boolean flags (`isLoading && isError`) that allow impossible combinations
- `type`/`status` field typed as `string` instead of a literal union
- Switch/match with no exhaustiveness guard

**TypeScript:**
```typescript
// BEFORE: invalid state possible (isLoading && isError both true)
interface FetchState { isLoading: boolean; isError: boolean; data: User | null; }

// AFTER: impossible states are unrepresentable
type FetchState =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'success'; data: User }
  | { status: 'error';   error: string };

function render(state: FetchState): string {
  switch (state.status) {
    case 'success': return state.data.name;  // data is User here
    case 'error':   return state.error;       // error is string here
    default: {
      const _exhaustive: never = state;       // compile error if case is missing
      throw new Error(`Unhandled: ${JSON.stringify(_exhaustive)}`);
    }
  }
}
```

**Rust** — use `enum`; **Java 17+** — use `sealed interface` with `record` implementations.

---

### 2. Phantom Types

**Intent:** Attach compile-time information to a type that has no runtime representation. Tracks whether data has been validated without adding runtime overhead.

**Code Review Red Flags:**
- Validated and unvalidated forms share the same type (both `string`)
- Validation documented in comments instead of enforced by the compiler
- Functions accepting raw user input where validated input is assumed

**TypeScript:**
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

**Intent:** Make structurally identical primitive types distinct so the compiler rejects misuse. Essential when multiple IDs or monetary values share the same underlying type.

**Code Review Red Flags:**
- `userId`, `orderId`, `productId` all typed as `number` or `string`
- Arguments silently swappable (compiles fine, wrong at runtime)
- Monetary amounts of different currencies typed identically

**TypeScript:**
```typescript
type UserId  = number & { readonly _brand: 'UserId' };
type OrderId = number & { readonly _brand: 'OrderId' };
type USD     = number & { readonly _brand: 'USD' };

function getOrder(userId: UserId, orderId: OrderId): Order { /* ... */ }
// getOrder(orderId, userId) → compile error: types incompatible
```

**Go** — `type UserID int64` creates distinct types; `GetOrder(UserID, OrderID)` rejects swapped arguments.
**Python** — `UserId = NewType('UserId', int)` catches misuse with mypy.

---

### 4. Generic Constraints

**Intent:** Bound type parameters to express what capabilities a type must have. Eliminates `any` casts inside generic implementations and catches invalid usage at call sites.

**Code Review Red Flags:**
- Unconstrained `T` that is then cast to a concrete type inside the function body
- `any` where a constrained generic would be correct
- Copy-pasted code for `string` / `number` variants that could be unified

**TypeScript:**
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

**Rust** — `fn log_all<T: Display>(items: &[T])` bounds with traits.
**Java** — `<T extends Comparable<T>> T max(List<T> items)` uses bounded wildcards.

---

### 5. Type Narrowing / Type Guards

**Intent:** Use runtime checks the type system understands to narrow a broad type. Prefer named guard functions over bare `as` casts so validation is reusable and testable.

**Code Review Red Flags:**
- `value as SpecificType` with no preceding runtime check
- `as unknown as T` — double assertion that bypasses the type system entirely
- Inline `typeof`/`instanceof` checks duplicated across call sites instead of extracted into a guard

**TypeScript:**
```typescript
// BEFORE — throws at runtime if shape is wrong
function process(value: unknown): string { return (value as { name: string }).name; }

// AFTER — compiler-understood guard
interface Named { name: string; }

function isNamed(value: unknown): value is Named {
  return typeof value === 'object' && value !== null &&
    'name' in value && typeof (value as Named).name === 'string';
}

function process(value: unknown): string {
  if (!isNamed(value)) throw new Error(`Expected Named: ${JSON.stringify(value)}`);
  return value.name;  // typed Named here — no cast
}
```

**Python 3.10+** — `TypeGuard[T]` return annotation on a predicate function.

---

### 6. Immutable Types

**Intent:** Express at the type level that a value must not be modified after construction. Documents intent, prevents accidental mutation, and enables safe sharing across references.

**Code Review Red Flags:**
- Mutable interfaces for value objects, DTOs, or configuration
- Arrays typed as `T[]` passed into functions that must not mutate them
- Shared configuration objects without `readonly` or `Object.freeze`

**TypeScript:**
```typescript
// BEFORE — nothing prevents mutation
interface Config { apiUrl: string; timeout: number; }

// AFTER
type Config = Readonly<{ apiUrl: string; timeout: number; }>;

// Deep readonly for nested structures
type DeepReadonly<T> = { readonly [K in keyof T]: DeepReadonly<T[K]> };
```

**Rust** — immutable by default; mutation requires explicit `mut`, visible at every call site.

Cross-reference: `refactor-organizing-data` — "Encapsulate Field" controls how values are constructed and changed.

---

### 7. Newtype Pattern

**Intent:** Wrap a primitive in a named type to attach semantic meaning and enforce a single validation point. The wrapper type is incompatible with the raw primitive.

**Code Review Red Flags:**
- Raw `string` used for email addresses, URLs, slugs, or tokens
- Raw `number` for monetary amounts, percentages, or physical units
- Validation logic copy-pasted wherever the raw primitive is used

**TypeScript:**
```typescript
class Email {
  private constructor(readonly value: string) {}
  static parse(raw: string): Email {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw)) throw new Error(`Invalid email: ${raw}`);
    return new Email(raw);
  }
}

function sendEmail(to: Email): void { /* raw strings rejected by compiler */ }
```

**Rust** — `struct Email(String)` with a `parse` constructor; zero runtime overhead.
**Go** — `type Email string` with a `ParseEmail(raw string) (Email, error)` factory.

---

### 8. Result / Option Types

**Intent:** Represent success/failure and presence/absence as first-class types instead of null returns or exceptions. Forces callers to handle both cases; makes the error path visible in the signature.

**Code Review Red Flags:**
- Functions returning `T | null` for error cases (not just absence)
- `try/catch` used for control flow rather than truly exceptional conditions
- Error objects returned but ignorable by the caller without compiler enforcement

**TypeScript:**
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
else           console.error(result.error);  // both branches explicit
```

**Rust** — `Result<T, E>` and `Option<T>` are built into the language; `.unwrap()` is a red flag in production code.

Cross-reference: `refactor-functional-patterns` — Functors/Monads section covers chaining Results with `map`/`flatMap`.

---

### 9. Builder Pattern with Types

**Intent:** Use the type system to enforce that all required fields are set before `build()` is callable. Moves completeness validation from runtime to compile time.

**Code Review Red Flags:**
- Builder's `build()` throws at runtime for missing required fields
- Required and optional fields are indistinguishable in the builder's type
- Tests needed to verify missing fields cause errors (should be a compile error)

**TypeScript (type-state builder):**
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

// build() only exists on the intersection type containing all required fields
interface UserBuilder<State extends { name: string; email: string }> {
  build(): User;
}

UserBuilder.create().withName('Alice').withEmail('a@b.com').build();  // OK
UserBuilder.create().withName('Alice').build();  // compile error: build() does not exist
```

---

### 10. Conditional Types / Type-Level Programming

**Intent:** Compute types from other types using conditional logic, enabling precise return types for overloaded functions and eliminating duplicated type information.

**Code Review Red Flags:**
- `any` return type when the actual return depends on an input type
- Function overloads with identical bodies but slightly different signatures that could be unified
- Type logic duplicated across multiple files instead of centralized

**TypeScript:**
```typescript
// Unwrap Promise — infer extracts the inner type
type Awaited<T> = T extends Promise<infer U> ? Awaited<U> : T;

// Element type from array
type ElementOf<T> = T extends readonly (infer U)[] ? U : never;

type A = ElementOf<string[]>;   // string
type B = ElementOf<number[][]>; // number[]
```

**Use sparingly.** Prefer discriminated unions and generic constraints for most problems. Reserve conditional types for library-level abstractions where the precision justifies the complexity.

---

## Type System Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **`any` / `Object` abuse** | Bypassing the type system instead of expressing the actual type | Replace with `unknown` (forces narrowing), a proper interface, or a generic constraint |
| **Type assertion overuse** | `as SomeType` hides real type errors; the compiler trusts you instead of checking | Add a runtime type guard; reserve `as` for already-narrowed values |
| **Stringly-typed APIs** | String params where a literal union or enum prevents typos | Replace with a discriminated union or string literal union |
| **Primitive obsession** | `number` for age, price, and quantity — no distinction between them | Apply Branded Types or the Newtype Pattern per semantic domain |
| **Overly complex generics** | Five-plus type parameters with nested conditionals harm readability | Extract intermediate type aliases; split into simpler overloads if possible |
| **Parallel boolean flags** | `isLoading`, `isError`, `isSuccess` allow impossible combinations | Replace with a Discriminated Union |

**Stringly-typed API — example:**
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

- `refactor-organizing-data` — "Replace Data Value with Object" and "Replace Type Code with Subclasses" are the refactoring moves that introduce Newtype and Discriminated Union patterns
- `language-specific-idioms` — Language-specific idioms for Rust enums, Go type aliases, Python `NewType`, and Java sealed classes
- `refactor-functional-patterns` — Immutability and Result/Option types align with functional patterns; Functors/Monads section covers chaining Results
- `detect-code-smells` — "Primitive Obsession" resolves to Branded Types; "Temporary Field" resolves to Discriminated Unions
