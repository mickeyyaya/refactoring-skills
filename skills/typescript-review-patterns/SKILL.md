---
name: typescript-review-patterns
description: Deep TypeScript-specific code review guide covering type escape hatches (any/as/!), type narrowing, async/Promise pitfalls, React hook rules, module patterns, and immutability. Load this skill when reviewing TypeScript or TSX code to catch type-system misuse, async bugs, and React antipatterns that generic review skills miss. Pair with review-accuracy-calibration to calibrate severity before posting comments.
---

# TypeScript Code Review Patterns

## Overview

TypeScript adds a rich static type system on top of JavaScript, but the type system has escape hatches — and those escape hatches are where most TypeScript-specific bugs hide. A reviewer who does not know where the safety net has holes will miss real defects while flagging non-issues.

This skill covers five high-value review dimensions unique to TypeScript: type escape hatches (`any`, `as`, `!`, `@ts-ignore`), type narrowing (discriminated unions, type guards), async/Promise pitfalls (unhandled rejections, floating promises), React hook rules (stale closures, dependency arrays), and module patterns (barrel exports, `import type`).

Load alongside `review-accuracy-calibration` to score confidence before posting.

## Quick Reference

| Review Dimension | Severity | Primary Red Flag |
|---|---|---|
| `any` on public API boundary | HIGH | `param: any` or `: any` in exported function |
| `as` assertion without prior narrowing | HIGH | `value as SpecificType` after `JSON.parse` or `fetch` |
| Non-null assertion `!` | MEDIUM | `obj!.prop` where null is plausible |
| `@ts-ignore` without explanation | MEDIUM | suppress comment with no linked issue |
| Missing type guard (`is`) | MEDIUM | boolean check function used as narrowing |
| Unhandled Promise rejection | HIGH | `async` called without `await` or `.catch()` |
| Floating promise | HIGH | Promise expression with no `await` or handler |
| async in `forEach` | HIGH | `arr.forEach(async (x) => ...)` — errors swallowed |
| `Promise.all` swallows partial failure | MEDIUM | use `allSettled` when partial success matters |
| Stale closure in `useEffect` | HIGH | captured variable missing from dependency array |
| Missing dep in dependency array | HIGH | `useEffect(() => { fn(x) }, [])` — `x` missing |
| Conditional hook call | CRITICAL | `if (cond) { useState(...) }` inside component |
| `useCallback`/`useMemo` overuse | NIT | wrapping cheap callbacks without referential need |
| Barrel export blocking tree-shaking | MEDIUM | `export * from './utils'` in public library API |
| Missing `import type` | NIT | value import used only as a type |
| Mutable reducer state | HIGH | direct `state.items.push(...)` in reducer function |
| `Object` or `Function` type | MEDIUM | `param: Object` instead of typed interface |
| Numeric enum footguns | LOW | numeric enum used in serialized or flag context |

## Type Escape Hatches

TypeScript's escape hatches disable the compiler. Every use is a potential hidden bug. Review each one for justification.

### `any` Type

`any` disables all type checking on a value and propagates — an `any` return type makes every caller untyped.

**Before — type system silenced:**
```typescript
// WRONG: any propagates to callers
function parseConfig(raw: unknown): any {
  return JSON.parse(raw as string);
}
const config = parseConfig(input);
config.timeout.toLowerCase(); // No TS error — runtime crash if timeout is a number
```

**After — typed return:**
```typescript
interface AppConfig { timeout: number; retries: number; endpoint: string; }

function parseConfig(raw: unknown): AppConfig {
  const parsed = JSON.parse(raw as string);
  if (typeof parsed.timeout !== 'number') throw new Error('Invalid config');
  return parsed as AppConfig;
}
```

Severity: `any` on exported API → HIGH. Internal `any` in leaf function → LOW. Generated code with TODO → NIT.

### `as` Assertions

`as T` tells the compiler to trust a cast without any runtime check. It is a lie when the value is not actually T.

**Before — hidden runtime crash:**
```typescript
// WRONG: API shape is unknown at runtime
const user = await fetchUser() as User;
console.log(user.profile.avatar.url); // crashes if profile is null
```

**After — validated before using:**
```typescript
const raw = await fetchUser();
if (!isUser(raw)) throw new Error('Unexpected user shape from API');
const user: User = raw; // safe: isUser validates shape
```

Flag `as SomeType` after `JSON.parse`, `fetch`, or `localStorage.getItem` at HIGH. Double-cast (`as unknown as T`) is always HIGH.

### Non-null Assertion `!`

`obj!` asserts not null/undefined. If wrong, it throws at runtime with no stack context.

**Before:**
```typescript
const input = document.getElementById('username')!;
input.value = ''; // crashes on pages where input is absent
```

**After:**
```typescript
const input = document.getElementById('username');
if (!(input instanceof HTMLInputElement)) throw new Error('username input missing');
input.value = '';
```

### `@ts-ignore` and `@ts-expect-error`

Both silence errors on the next line. Check: is there a comment explaining why? Is there a tracking issue? Could the real type error be fixed instead?

```typescript
// WRONG: no explanation
// @ts-ignore
const result = legacyLib.doThing(input);

// BETTER: explanation + issue link
// @ts-expect-error: legacyLib types broken in v2.3 — see issue #482
const result = legacyLib.doThing(input);
```

## Type Narrowing and Guards

TypeScript's control-flow analysis narrows types based on checks. Wrong or missing narrowing means the type system does not catch misuse.

### Discriminated Unions

Use a shared `kind`/`type` literal field and switch for exhaustive narrowing.

```typescript
type Shape = { kind: 'circle'; radius: number } | { kind: 'rect'; width: number; height: number };

// WRONG: bypasses narrowing entirely
function area(s: Shape) { return (s as any).width * (s as any).height; }

// CORRECT: exhaustive switch with never check
function area(s: Shape): number {
  switch (s.kind) {
    case 'circle': return Math.PI * s.radius ** 2;
    case 'rect': return s.width * s.height;
    default: {
      const _exhaustive: never = s;
      throw new Error(`Unknown shape: ${JSON.stringify(_exhaustive)}`);
    }
  }
}
```

### Custom Type Guards with `is`

A guard function must return `value is T`, not `boolean`. Without the predicate, narrowing is lost at the call site.

**Before — narrowing lost:**
```typescript
function isUser(value: unknown): boolean { // WRONG: returns boolean
  return typeof value === 'object' && value !== null && 'id' in value;
}
if (isUser(data)) { data.id; } // TS error: data still unknown
```

**After — proper type predicate:**
```typescript
function isUser(value: unknown): value is User {
  return typeof value === 'object' && value !== null &&
    typeof (value as Record<string, unknown>).id === 'string';
}
if (isUser(data)) { data.id; } // OK: narrowed to User
```

### `satisfies` Keyword

`satisfies` validates a value against a type without widening it. Prefer over `as` when the goal is validation, not casting.

```typescript
// WRONG: widens palette.red to string | number[]
const palette = { red: [255, 0, 0], green: '#00ff00' } as Record<string, string | number[]>;

// CORRECT: validates shape, palette.red stays number[]
const palette = { red: [255, 0, 0], green: '#00ff00' } satisfies Record<string, string | number[]>;
```

## Async/Promise Pitfalls

Async bugs are invisible at review time because they only surface under error conditions or load.

### Unhandled Rejections and Floating Promises

A Promise that rejects with no `.catch()` or `await` crashes a Node process (Node 15+) or silently fails in browsers.

**Before — floating promise:**
```typescript
function saveUser(user: User): void {
  db.save(user); // Promise returned, rejection ignored
}
```

**After — awaited or explicitly fire-and-forget:**
```typescript
async function saveUser(user: User): Promise<void> {
  await db.save(user);
}
// Or if intentionally fire-and-forget:
void db.save(user).catch((err) => logger.error('saveUser failed', err));
```

### async in `forEach`

`Array.prototype.forEach` does not await async callbacks. Errors are swallowed and the caller continues before callbacks complete.

**Before — errors swallowed:**
```typescript
// WRONG: forEach ignores returned Promises
userIds.forEach(async (id) => { await processUser(id); });
// continues immediately — exceptions vanish
```

**After — properly awaited:**
```typescript
// Sequential (order matters):
for (const id of userIds) { await processUser(id); }

// Concurrent with error propagation:
await Promise.all(userIds.map((id) => processUser(id)));
```

### `Promise.all` vs `Promise.allSettled`

`Promise.all` rejects on the first failure, abandoning in-flight operations. Use `Promise.allSettled` when partial success should be handled.

```typescript
// WRONG: single notification failure cancels all
await Promise.all(users.map((u) => sendNotification(u)));

// CORRECT: handle each outcome
const results = await Promise.allSettled(users.map((u) => sendNotification(u)));
const failed = results.filter((r) => r.status === 'rejected');
if (failed.length > 0) logger.warn(`${failed.length} notifications failed`);
```

### Error Handling in Async Functions

An `async` function that throws must be caught by its caller with `await` inside `try/catch`. Wrapping a non-awaited call in `try/catch` silently drops the rejection.

```typescript
// WRONG: try/catch cannot catch async rejection without await
try { fetchData(); } catch (e) { handleError(e); } // never runs

// CORRECT:
try { await fetchData(); } catch (e) { handleError(e); }
```

## React Hook Rules

React hooks have strict call-order rules. The `eslint-plugin-react-hooks` linter catches structural violations, but semantic violations (stale closures, wrong deps) require manual review.

### Stale Closures in useEffect

A closure captures variables at creation time. If a variable changes but is absent from the dependency array, the effect sees the stale value.

**Before — stale closure:**
```typescript
useEffect(() => {
  const id = setInterval(() => {
    console.log(count); // always logs 0 — stale closure
  }, 1000);
  return () => clearInterval(id);
}, []); // WRONG: count missing from dependency array
```

**After — dep fixed:**
```typescript
useEffect(() => {
  const id = setInterval(() => { console.log(count); }, 1000);
  return () => clearInterval(id);
}, [count]); // interval recreated when count changes
```

### Dependency Array Mistakes

- **Empty `[]` with captured vars** — stale closure (above)
- **Object/array literal in deps** — new reference every render, infinite loop
- **Inline function in deps without `useCallback`** — infinite loop

```typescript
// WRONG: new object reference every render triggers infinite loop
useEffect(() => { fetchData(options); }, [{ page, limit }]);

// CORRECT: primitive deps or memoized reference
useEffect(() => { fetchData({ page, limit }); }, [page, limit]);
```

### Conditional Hook Calls

Hooks must be called in the same order on every render. Calling hooks after a conditional return or inside an `if` statement violates this rule and corrupts state.

```typescript
// WRONG — CRITICAL: hook called conditionally
function UserProfile({ userId }: { userId?: string }) {
  if (!userId) return null; // early return before hook
  const [user, setUser] = useState<User | null>(null); // conditional call
}

// CORRECT: hooks before any conditional return
function UserProfile({ userId }: { userId?: string }) {
  const [user, setUser] = useState<User | null>(null);
  if (!userId) return null;
}
```

### `useCallback` and `useMemo` Overuse

Only memoize when the value is passed to a `React.memo` child or used as a dep in another hook. Wrapping every callback adds closure allocation overhead without benefit.

## Module and Import Patterns

### Barrel Exports and Tree-Shaking

`export * from './utils'` in a library can prevent bundlers from tree-shaking unused exports, inflating bundle size. Flag in library public APIs.

```typescript
// RISKY in libraries: consumers cannot tree-shake
export * from './formatters';
export * from './validators';

// BETTER: consumers import directly
import { formatDate } from 'mylib/formatters';
```

### Circular Dependencies

Circular imports cause `undefined` values at import time in CommonJS and init-order bugs in ESM. Fix by extracting shared types to a third module (`types.ts`) that both import.

### `import type` for Type-Only Imports

`import type` is erased at compile time, preventing accidental circular runtime dependencies and reducing bundle metadata.

```typescript
// WRONG: value import for type-only usage
import { UserService } from './UserService';
function getUser(service: UserService): Promise<User> { ... }

// CORRECT: erased at compile time
import type { UserService } from './UserService';
function getUser(service: UserService): Promise<User> { ... }
```

## Immutability Patterns

### `readonly` and `Readonly<T>`

Mark parameters and properties that should not be mutated. Prevents accidental in-place sort/splice.

```typescript
// WRONG: mutates caller's array
function sortUsers(users: User[]): User[] {
  return users.sort((a, b) => a.name.localeCompare(b.name));
}

// CORRECT: readonly parameter forces new array
function sortUsers(users: readonly User[]): User[] {
  return [...users].sort((a, b) => a.name.localeCompare(b.name));
}
```

### `as const` for Literal Types

Prevents type widening and enables union type derivation from arrays.

```typescript
// WRONG: type widened to string[]
const STATUSES = ['active', 'inactive', 'pending'];

// CORRECT: literal tuple, union derivable
const STATUSES = ['active', 'inactive', 'pending'] as const;
type Status = typeof STATUSES[number]; // 'active' | 'inactive' | 'pending'
```

### Reducer Mutation

Direct mutation in reducers causes React not to detect changes (reference equality unchanged).

```typescript
// WRONG: mutates state — React.memo misses the update
function reducer(state: State, action: Action): State {
  if (action.type === 'ADD_ITEM') {
    state.items.push(action.item); // mutation — same reference returned
    return state;
  }
  return state;
}

// CORRECT: new object returned
function reducer(state: State, action: Action): State {
  if (action.type === 'ADD_ITEM') {
    return { ...state, items: [...state.items, action.item] };
  }
  return state;
}
```

## Anti-Patterns

**`Object` and `Function` types** — `Object` matches any non-primitive but loses all type information. Use `Record<string, unknown>` or a typed interface. `Function` loses parameter and return types; use an explicit signature.

**Numeric enum footguns** — Any number is assignable to a numeric enum type, and reverse mapping adds bundle weight. Prefer string literal unions for safety and readability.

```typescript
// RISKY: Direction.Up === 0; any 0 is assignable
enum Direction { Up, Down, Left, Right }

// SAFER: only these values accepted
type Direction = 'Up' | 'Down' | 'Left' | 'Right';
```

**Class overuse** — When a module only needs functions and data, plain module-level exports are simpler and tree-shakeable. Reserve classes for stateful objects with encapsulated behavior.

## Cross-References

- `review-accuracy-calibration` — Apply confidence scoring (C1-C4) before posting any finding from this skill. TypeScript false positive risk is Medium: require C3 minimum for HIGH findings.
- `type-system-patterns` — Deeper coverage of generics, conditional types, mapped types
- `error-handling-patterns` — Async error handling strategy beyond the basics in this skill
- `performance-anti-patterns` — Bundle size impacts of barrel exports, enum reverse mapping, large dependency arrays
