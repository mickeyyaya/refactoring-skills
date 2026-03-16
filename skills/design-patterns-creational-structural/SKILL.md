---
name: design-patterns-creational-structural
description: Use when reviewing code for object creation problems or structural composition issues — covers all 12 GoF Creational (5) and Structural (7) patterns with intent, red flags, and refactoring cross-references
---

# Design Patterns: Creational and Structural

## Overview

GoF patterns are proven solutions to recurring object-oriented design problems. Creational patterns control how objects are created. Structural patterns control how objects are composed into larger structures. Recognizing which pattern is — or should be — present is a core code review skill.

## When to Use

- Reviewing code where object instantiation logic is scattered or tightly coupled to concrete classes
- Reviewing code where class hierarchies are becoming difficult to extend independently
- Identifying missing abstraction that causes duplication or fragility
- Recommending a named pattern so the team shares vocabulary for the change

## Quick Reference

| Pattern | Category | Core Problem Solved | Key Red Flag |
|---------|----------|--------------------|----|
| Factory Method | Creational | Subclasses choose which class to instantiate | `new ConcreteClass()` scattered across callers |
| Abstract Factory | Creational | Create families of related objects | Mixed product-family objects in one branch |
| Builder | Creational | Construct complex objects step by step | Telescoping constructors or long optional-param lists |
| Prototype | Creational | Clone objects without coupling to their class | Manual field-by-field copy code |
| Singleton | Creational | One shared instance (use sparingly) | Global state hiding dependencies |
| Adapter | Structural | Bridge incompatible interfaces | Conversion logic duplicated at every call site |
| Bridge | Structural | Vary abstraction and implementation independently | Exponential subclass explosion |
| Composite | Structural | Treat leaves and composites uniformly | `instanceof` checks to distinguish leaf vs. group |
| Decorator | Structural | Add behavior dynamically without subclassing | Subclass explosion for every feature combination |
| Facade | Structural | Simplified interface to a complex subsystem | Caller knows too many internal classes |
| Flyweight | Structural | Share fine-grained objects to reduce memory | Thousands of near-identical objects with redundant state |
| Proxy | Structural | Control access to another object | Cross-cutting concerns duplicated across many callers |

---

## Creational Patterns

### 1. Factory Method

**Intent:** Define an interface for creating an object; let subclasses decide which class to instantiate.

**When to Use:** Type of object unknown until runtime; subclasses should control what they create.

**When NOT to Use:** Object creation is simple and type never varies — a plain constructor is clearer. Avoid adding another inheritance layer when the hierarchy is already complex.

```typescript
abstract class Notifier {
  abstract createChannel(): Channel;
  send(msg: string): void { this.createChannel().deliver(msg); }
}
class EmailNotifier extends Notifier { createChannel() { return new EmailChannel(); } }
class SmsNotifier extends Notifier   { createChannel() { return new SmsChannel(); }   }
```

**Code Review Red Flags**
- `new ConcreteClass()` inside business logic — creation should live in a factory
- Adding a new type requires editing an existing `if/switch` block (Open/Closed violation)
- Tests cannot swap the created object without changing production code

**Refactoring link:** Replace Constructor with Factory Method (`refactor-simplifying-method-calls`)

---

### 2. Abstract Factory

**Intent:** Create families of related objects without specifying their concrete classes.

**When to Use:** System must work with multiple product families (e.g., light/dark theme, AWS/GCP). Products from the same family must be used together.

**When NOT to Use:** Only one product family exists. Adding new product *types* requires changing all factory interfaces — use Factory Method instead.

```typescript
interface UIFactory { createButton(): Button; createCheckbox(): Checkbox; }
class MacUIFactory implements UIFactory {
  createButton()   { return new MacButton();   }
  createCheckbox() { return new MacCheckbox(); }
}
```

**Code Review Red Flags**
- Objects from different families mixed together inside a single `if (platform === 'mac')` branch
- Family selection repeated in every file that creates widgets — factory not centralized
- No interface tying the family together

---

### 3. Builder

**Intent:** Construct a complex object step by step, separating construction from representation.

**When to Use:** Object has many optional parameters (telescoping constructor problem); step-by-step construction must be validated or ordered.

**When NOT to Use:** Object is simple — a plain constructor or object literal is cleaner.

```typescript
class QueryBuilder {
  private conditions: string[] = [];
  from(table: string): this  { this.table = table; return this; }
  where(cond: string): this  { this.conditions.push(cond); return this; }
  build(): Query             { return new Query(this.table, this.conditions); }
}
```

**Code Review Red Flags**
- Constructor with 5+ parameters, many nullable or in a fixed-but-confusing order
- Object escapes in a partially-initialized state — no terminal `build()` step enforces completeness
- Caller passes `null`/`undefined` for parameters they don't need

**Refactoring link:** Introduce Parameter Object (`refactor-simplifying-method-calls`)

---

### 4. Prototype

**Intent:** Create new objects by cloning a prototypical instance.

**When to Use:** Object creation is expensive (DB/network); need copies with minor variation.

**When NOT to Use:** Objects contain non-cloneable resources (file handles, connections). Shallow copy is silently wrong because nested objects are shared.

```typescript
class UserProfile {
  clone(): UserProfile { return new UserProfile(this.name, { ...this.settings }); }
}
```

**Code Review Red Flags**
- Manual field-by-field copy repeated at call sites instead of a `clone()` method
- Shallow spread (`{ ...obj }`) on objects with nested mutable reference types
- Clone logic misses fields added after the pattern was first introduced

---

### 5. Singleton

**Intent:** Ensure a class has only one instance and provide a global access point.

**When to Use:** Truly shared, managed resources — logger, config reader, connection pool — only when dependency injection is genuinely impractical.

**When NOT to Use:** Prefer DI almost always. Singletons make testing painful, hide dependencies, and complicate concurrent environments.

```typescript
class Logger {
  private static instance: Logger | null = null;
  private constructor() {}
  static getInstance(): Logger { return (Logger.instance ??= new Logger()); }
}
```

**Code Review Red Flags**
- `Singleton.getInstance()` called inside business logic — hides a dependency; inject it instead
- Tests cannot reset the singleton between runs — leads to test pollution
- Multiple Singletons coordinating with each other — consider a proper service layer

---

## Structural Patterns

### 6. Adapter

**Intent:** Convert the interface of a class into another interface that clients expect.

**When to Use:** Integrating a third-party library or legacy system whose interface you cannot change.

**When NOT to Use:** You control both interfaces — refactor one directly. The mismatch is so large the adapter becomes its own complex system (use an Anti-Corruption Layer).

```typescript
class PaymentGatewayAdapter implements PaymentProcessor {
  constructor(private readonly gateway: LegacyGateway) {}
  charge(amount: Money): PaymentResult {
    return { success: this.gateway.makePayment(amount.cents, amount.currency) };
  }
}
```

**Code Review Red Flags**
- Conversion logic duplicated at every call site instead of centralized in one adapter
- Adapter accumulates state or business logic — it should be a thin translation layer only
- Adapter wraps an adapter wraps an adapter — indicates mismatched abstractions at a deeper level

**Refactoring link:** Extract Class, Move Method (`refactor-moving-features`)

---

### 7. Bridge

**Intent:** Decouple an abstraction from its implementation so the two can vary independently.

**When to Use:** Two independent dimensions of variation would cause a subclass explosion (2 shapes × 3 renderers = 6 subclasses without Bridge).

**When NOT to Use:** Only one implementation exists — the indirection has no benefit.

```typescript
class Circle extends Shape {
  constructor(renderer: Renderer, private radius: number) { super(renderer); }
  draw(): void { this.renderer.renderCircle(this.radius); }
}
```

**Code Review Red Flags**
- Class names of the form `WindowsCircle`, `LinuxCircle`, `MacCircle` — subclass explosion
- Changing the backend requires touching every shape subclass
- Abstraction and implementation mixed in the same hierarchy

---

### 8. Composite

**Intent:** Compose objects into tree structures; treat leaves and composites uniformly.

**When to Use:** Tree-like structures — file systems, UI component trees, expression trees.

**When NOT to Use:** Hierarchy is not truly recursive; forcing a common interface on very different types bloats the interface with optional methods.

```typescript
interface FileSystemItem { name(): string; size(): number; }
class File      implements FileSystemItem { size() { return this._size; } }
class Directory implements FileSystemItem { size() { return this.children.reduce((s, c) => s + c.size(), 0); } }
```

**Code Review Red Flags**
- `instanceof` checks to distinguish leaf from composite — the pattern eliminates these
- Composite children exposed as a public mutable array
- Leaf classes forced to implement `add()`/`remove()` with no-ops or thrown errors

---

### 9. Decorator

**Intent:** Attach additional responsibilities to an object dynamically; a flexible alternative to subclassing.

**When to Use:** Add behavior to individual objects without affecting others; behavior combinations would cause a subclass explosion if done via inheritance.

**When NOT to Use:** The decorated interface is large — maintaining it in every wrapper is tedious. Order of decoration matters in non-obvious ways that aren't enforced.

```typescript
class CompressionDecorator implements DataSource {
  constructor(private readonly wrapped: DataSource) {}
  write(data: string): void { this.wrapped.write(compress(data)); }
  read(): string            { return decompress(this.wrapped.read()); }
}
```

**Code Review Red Flags**
- Subclasses like `CompressedEncryptedFileDataSource` — Decorator eliminates this explosion
- Decorator modifies wrapped object's state instead of delegating
- Stack of decorators applied inconsistently across call sites

**Refactoring link:** Replace Inheritance with Delegation (`refactor-generalization`)

---

### 10. Facade

**Intent:** Provide a simplified interface to a complex subsystem.

**When to Use:** Callers need only a small slice of a subsystem's capabilities; layering helps separate external API from internal implementation.

**When NOT to Use:** The simplification hides behavior callers legitimately need to control. Facade is growing into a God Object — it should delegate, not accumulate logic.

```typescript
class VideoConverter {
  convert(inputPath: string): Buffer {
    const frames = this.decoder.decode(inputPath);
    const audio  = this.mixer.mix(frames);
    return this.encoder.encode(frames, audio);
  }
}
```

**Code Review Red Flags**
- Callers import 5+ internal subsystem classes for a common workflow — missing facade
- Facade contains business logic instead of delegating
- Facade is the only entry point, removing flexibility for advanced callers

---

### 11. Flyweight

**Intent:** Use sharing to support large numbers of fine-grained objects efficiently.

**When to Use:** Thousands-to-millions of objects that share most of their state, and memory usage is a measured problem.

**When NOT to Use:** Object count is not large enough to matter. Objects carry significant unique state that cannot be shared.

```typescript
class CharacterStyleFactory {
  private cache = new Map<string, CharacterStyle>();
  get(font: string, size: number, bold: boolean): CharacterStyle {
    const key = `${font}:${size}:${bold}`;
    return this.cache.get(key) ?? (this.cache.set(key, new CharacterStyle(font, size, bold)), this.cache.get(key)!);
  }
}
```

**Code Review Red Flags**
- Applied without a memory profile — premature Flyweight adds complexity with no measurable gain
- Extrinsic (context-specific) state stored inside the flyweight — breaks sharing
- Factory returns mutable objects — one caller corrupts shared state for all others

---

### 12. Proxy

**Intent:** Provide a placeholder that controls access to another object.

**When to Use:** Lazy initialization (Virtual Proxy), access control (Protection Proxy), caching (Caching Proxy), logging/audit (Logging Proxy).

**When NOT to Use:** The framework already provides middleware or interceptors — don't reinvent them. Avoid in hot paths where the indirection latency is unacceptable.

```typescript
class LazyImage implements ImageLoader {
  private real: RealImage | null = null;
  display(): void {
    this.real ??= new RealImage(this.path); // create only on first use
    this.real.display();
  }
}
```

**Code Review Red Flags**
- Logging, auth checks, or caching copy-pasted across many service methods — a single Proxy handles it
- Proxy does not implement the same interface as the subject — callers cannot substitute it transparently
- Proxy accumulates business logic over time instead of delegating cleanly

---

## Decision Flowchart

```
Object creation problem?
  ├── Type unknown until runtime, subclass controls creation  → Factory Method
  ├── Need a family of related objects                        → Abstract Factory
  ├── Many optional constructor params / ordered construction → Builder
  ├── Clone an expensive-to-create object                    → Prototype
  └── Truly shared single resource (prefer DI first)         → Singleton

Structural composition problem?
  ├── Incompatible interface from a third party              → Adapter
  ├── Two independent axes of variation                      → Bridge
  ├── Tree structure (part-whole hierarchy)                  → Composite
  ├── Add/remove behavior dynamically                        → Decorator
  ├── Hide a complex subsystem                               → Facade
  ├── Huge number of similar objects, memory pressure        → Flyweight
  └── Control access, lazy load, cache, log                  → Proxy
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Singleton instead of dependency injection | Pass the shared object as a constructor parameter |
| Adapter accumulates state or business logic | Adapter should only translate — no logic |
| Composite forces no-op `add()`/`remove()` on leaves | Use a narrower leaf interface; uniform interface is a goal, not a mandate |
| Decorator mutates the wrapped object directly | Always delegate — the decorator owns the call, not the state |
| Facade becomes a God Object | Split into domain-specific facades when public methods exceed ~5 |
| Flyweight applied without a memory profile | Measure first — complexity is only justified by real memory pressure |

## Cross-References to Refactoring Skills

| Pattern | Refactoring Skill |
|---------|-------------------|
| Factory Method | Replace Constructor with Factory Method — `refactor-simplifying-method-calls` |
| Builder | Introduce Parameter Object — `refactor-simplifying-method-calls` |
| Adapter / Composite / Facade | Extract Class, Move Method — `refactor-moving-features` |
| Decorator | Replace Inheritance with Delegation — `refactor-generalization` |
| Any pattern introducing a new class | Extract Method — `refactor-composing-methods` |
