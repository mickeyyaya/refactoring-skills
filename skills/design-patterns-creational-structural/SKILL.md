---
name: design-patterns-creational-structural
description: Use when reviewing code for object creation problems or structural composition issues — covers all 12 GoF Creational (5) and Structural (7) patterns with intent, red flags, and refactoring cross-references
---

# Design Patterns: Creational and Structural

## Overview

Creational patterns control how objects are created. Structural patterns control how objects are composed into larger structures. Recognizing which pattern is — or should be — present is a core code review skill.

## When to Use

- Object instantiation logic scattered or tightly coupled to concrete classes
- Class hierarchies becoming difficult to extend independently
- Missing abstraction causing duplication or fragility

## Quick Reference

| Pattern | Category | Core Problem Solved | Key Red Flag |
|---------|----------|--------------------|----|
| Factory Method | Creational | Subclasses choose which class to instantiate | `new ConcreteClass()` scattered across callers |
| Abstract Factory | Creational | Create families of related objects | Mixed product-family objects in one branch |
| Builder | Creational | Construct complex objects step by step | Telescoping constructors or long optional-param lists |
| Prototype | Creational | Clone objects without coupling to class | Manual field-by-field copy code |
| Singleton | Creational | One shared instance (use sparingly) | Global state hiding dependencies |
| Adapter | Structural | Bridge incompatible interfaces | Conversion logic duplicated at every call site |
| Bridge | Structural | Vary abstraction and implementation independently | Exponential subclass explosion |
| Composite | Structural | Treat leaves and composites uniformly | `instanceof` checks for leaf vs. group |
| Decorator | Structural | Add behavior dynamically without subclassing | Subclass explosion for feature combinations |
| Facade | Structural | Simplified interface to complex subsystem | Caller knows too many internal classes |
| Flyweight | Structural | Share fine-grained objects to reduce memory | Thousands of near-identical objects |
| Proxy | Structural | Control access to another object | Cross-cutting concerns duplicated across callers |

---

## Creational Patterns

### 1. Factory Method

**Intent:** Define an interface for creating an object; let subclasses decide which class to instantiate.

**Use when** type is unknown until runtime and subclasses should control creation. **Skip when** creation is simple and type never varies, or hierarchy is already complex.

```typescript
abstract class Notifier {
  abstract createChannel(): Channel;
  send(msg: string): void { this.createChannel().deliver(msg); }
}
class EmailNotifier extends Notifier { createChannel() { return new EmailChannel(); } }
class SmsNotifier extends Notifier   { createChannel() { return new SmsChannel(); }   }
```

**Red Flags:** `new ConcreteClass()` in business logic; adding a type requires editing existing `if/switch` (Open/Closed violation); tests can't swap created object.

**Refactoring link:** Replace Constructor with Factory Method (`refactor-simplifying-method-calls`)

---

### 2. Abstract Factory

**Intent:** Create families of related objects without specifying concrete classes.

**Use when** system must work with multiple product families used together (light/dark theme, AWS/GCP). **Skip when** only one family exists or adding new product *types* requires changing all factory interfaces.

```typescript
interface UIFactory { createButton(): Button; createCheckbox(): Checkbox; }
class MacUIFactory implements UIFactory {
  createButton()   { return new MacButton();   }
  createCheckbox() { return new MacCheckbox(); }
}
```

**Red Flags:** objects from different families mixed in one `if (platform)` branch; family selection repeated everywhere; no interface tying the family together.

---

### 3. Builder

**Intent:** Construct complex objects step by step, separating construction from representation.

**Use when** many optional parameters (telescoping constructor) or ordered construction needing validation. **Skip when** object is simple enough for a plain constructor.

```typescript
class QueryBuilder {
  private conditions: string[] = [];
  from(table: string): this  { this.table = table; return this; }
  where(cond: string): this  { this.conditions.push(cond); return this; }
  build(): Query             { return new Query(this.table, this.conditions); }
}
```

**Red Flags:** constructor with 5+ params, many nullable; object escapes partially initialized (no terminal `build()`); caller passes `null` for unneeded params.

**Refactoring link:** Introduce Parameter Object (`refactor-simplifying-method-calls`)

---

### 4. Prototype

**Intent:** Create new objects by cloning a prototypical instance.

**Use when** creation is expensive (DB/network) and copies need minor variation. **Skip when** objects contain non-cloneable resources or shallow copy silently shares nested mutable objects.

```typescript
class UserProfile {
  clone(): UserProfile { return new UserProfile(this.name, { ...this.settings }); }
}
```

**Red Flags:** manual field-by-field copy at call sites; shallow spread on objects with nested mutables; clone logic misses fields added later.

---

### 5. Singleton

**Intent:** Ensure one instance with a global access point.

**Use when** truly shared managed resources (logger, config, connection pool) only when DI is genuinely impractical. **Skip when** possible — prefer DI. Singletons make testing painful and hide dependencies.

```typescript
class Logger {
  private static instance: Logger | null = null;
  private constructor() {}
  static getInstance(): Logger { return (Logger.instance ??= new Logger()); }
}
```

**Red Flags:** `Singleton.getInstance()` in business logic (inject instead); tests can't reset between runs; multiple Singletons coordinating (use a service layer).

---

## Structural Patterns

### 6. Adapter

**Intent:** Convert one interface into another that clients expect.

**Use when** integrating third-party/legacy systems you can't change. **Skip when** you control both interfaces (refactor directly), or mismatch is so large the adapter becomes its own system.

```typescript
class PaymentGatewayAdapter implements PaymentProcessor {
  constructor(private readonly gateway: LegacyGateway) {}
  charge(amount: Money): PaymentResult {
    return { success: this.gateway.makePayment(amount.cents, amount.currency) };
  }
}
```

**Red Flags:** conversion logic duplicated at every call site; adapter accumulates state or business logic (should be thin translation only); adapter-wrapping-adapter chains.

**Refactoring link:** Extract Class, Move Method (`refactor-moving-features`)

---

### 7. Bridge

**Intent:** Decouple abstraction from implementation so both vary independently.

**Use when** two independent dimensions of variation would cause subclass explosion. **Skip when** only one implementation exists.

```typescript
class Circle extends Shape {
  constructor(renderer: Renderer, private radius: number) { super(renderer); }
  draw(): void { this.renderer.renderCircle(this.radius); }
}
```

**Red Flags:** names like `WindowsCircle`, `LinuxCircle` (subclass explosion); changing backend touches every shape subclass; abstraction and implementation mixed in same hierarchy.

---

### 8. Composite

**Intent:** Compose objects into tree structures; treat leaves and composites uniformly.

**Use when** tree-like structures (file systems, UI trees, expression trees). **Skip when** hierarchy isn't truly recursive, or forcing a common interface bloats it with optional methods.

```typescript
interface FileSystemItem { name(): string; size(): number; }
class File      implements FileSystemItem { size() { return this._size; } }
class Directory implements FileSystemItem { size() { return this.children.reduce((s, c) => s + c.size(), 0); } }
```

**Red Flags:** `instanceof` checks for leaf vs. composite; children exposed as mutable array; leaves forced to implement `add()`/`remove()` with no-ops.

---

### 9. Decorator

**Intent:** Attach responsibilities dynamically; flexible alternative to subclassing.

**Use when** adding behavior to individual objects without affecting others, avoiding subclass explosion. **Skip when** decorated interface is large (tedious to maintain wrappers) or decoration order matters non-obviously.

```typescript
class CompressionDecorator implements DataSource {
  constructor(private readonly wrapped: DataSource) {}
  write(data: string): void { this.wrapped.write(compress(data)); }
  read(): string            { return decompress(this.wrapped.read()); }
}
```

**Red Flags:** subclasses like `CompressedEncryptedFileDataSource`; decorator modifies wrapped object's state instead of delegating; decorators applied inconsistently across call sites.

**Refactoring link:** Replace Inheritance with Delegation (`refactor-generalization`)

---

### 10. Facade

**Intent:** Simplified interface to a complex subsystem.

**Use when** callers need only a small slice of subsystem capabilities. **Skip when** simplification hides behavior callers need, or Facade grows into a God Object.

```typescript
class VideoConverter {
  convert(inputPath: string): Buffer {
    const frames = this.decoder.decode(inputPath);
    const audio  = this.mixer.mix(frames);
    return this.encoder.encode(frames, audio);
  }
}
```

**Red Flags:** callers import 5+ internal subsystem classes for common workflow; Facade contains business logic instead of delegating; Facade is the only entry point, removing flexibility.

---

### 11. Flyweight

**Intent:** Share fine-grained objects to reduce memory usage.

**Use when** thousands-to-millions of objects sharing most state, with measured memory pressure. **Skip when** object count isn't large enough or objects carry significant unique state.

```typescript
class CharacterStyleFactory {
  private cache = new Map<string, CharacterStyle>();
  get(font: string, size: number, bold: boolean): CharacterStyle {
    const key = `${font}:${size}:${bold}`;
    return this.cache.get(key) ?? (this.cache.set(key, new CharacterStyle(font, size, bold)), this.cache.get(key)!);
  }
}
```

**Red Flags:** applied without memory profile (premature complexity); extrinsic state stored inside flyweight (breaks sharing); factory returns mutable objects (one caller corrupts shared state).

---

### 12. Proxy

**Intent:** Placeholder controlling access to another object (lazy init, access control, caching, logging).

**Use when** cross-cutting concerns need centralization. **Skip when** framework provides middleware/interceptors, or indirection latency matters in hot paths.

```typescript
class LazyImage implements ImageLoader {
  private real: RealImage | null = null;
  display(): void {
    this.real ??= new RealImage(this.path);
    this.real.display();
  }
}
```

**Red Flags:** logging/auth/caching copy-pasted across service methods; Proxy doesn't implement same interface as subject; Proxy accumulates business logic.

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
| Singleton instead of DI | Pass shared object as constructor parameter |
| Adapter accumulates state/logic | Adapter should only translate |
| Composite forces no-op `add()`/`remove()` on leaves | Narrower leaf interface; uniformity is a goal, not mandate |
| Decorator mutates wrapped object | Always delegate — decorator owns the call, not the state |
| Facade becomes God Object | Split into domain-specific facades when methods exceed ~5 |
| Flyweight without memory profile | Measure first — complexity only justified by real pressure |

## Cross-References

| Pattern | Refactoring Skill |
|---------|-------------------|
| Factory Method | Replace Constructor with Factory Method — `refactor-simplifying-method-calls` |
| Builder | Introduce Parameter Object — `refactor-simplifying-method-calls` |
| Adapter / Composite / Facade | Extract Class, Move Method — `refactor-moving-features` |
| Decorator | Replace Inheritance with Delegation — `refactor-generalization` |
