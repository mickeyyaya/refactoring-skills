---
name: design-patterns-behavioral
description: Use when reviewing code for communication and responsibility problems between objects — covers all 11 GoF Behavioral patterns with intent, red flags, and refactoring cross-references
---

# Design Patterns: Behavioral

## Overview

Behavioral patterns address how objects communicate and distribute responsibility. They replace tangled conditional logic, tight coupling, and ad-hoc event wiring with well-named structures. Recognizing which pattern is — or should be — present is a core code review skill.

## When to Use

- Large `switch`/`if-else` blocks branching on type or state
- Tightly coupled objects calling each other in every direction
- Duplicated algorithm logic with only small steps varying
- Event/notification systems needing correctness and scalability review

## Quick Reference

| Pattern | Core Problem Solved | Key Red Flag |
|---------|---------------------|--------------|
| Chain of Responsibility | Decouple sender from receiver; multiple handlers | Hardcoded handler cascade in caller |
| Command | Encapsulate request as object; undo/queue | Method calls not storable or reversible |
| Iterator | Uniform traversal without exposing internals | Callers access internal array fields directly |
| Mediator | Replace many-to-many with central coordinator | Objects holding refs to many unrelated peers |
| Memento | Save/restore state without breaking encapsulation | Caller copies internal fields for undo |
| Observer | Notify dependents of state changes automatically | Producer manually calls every consumer |
| State | Object changes behavior as state changes | Giant `switch (this.state)` in multiple methods |
| Strategy | Interchangeable algorithms at runtime | `if (type === 'A') algoA() else algoB()` |
| Template Method | Fix algorithm structure; vary steps | Copy-pasted algorithm with 1-2 lines differing |
| Visitor | Add operations without modifying hierarchy | New `instanceof` branch per operation |
| Interpreter | Evaluate sentences in a simple grammar | Ad-hoc string parsing scattered across codebase |

---

## Behavioral Patterns

### 1. Strategy *(most commonly applied)*

**Intent:** Define a family of algorithms, encapsulate each one, and make them interchangeable.

**Use when** multiple algorithms chosen at runtime need independent testing. **Skip when** only one algorithm exists or a single boolean flag suffices.

```typescript
interface PricingStrategy {
  calculate(base: number, qty: number): number;
}
class StandardPricing implements PricingStrategy {
  calculate(base: number, qty: number) { return base * qty; }
}
class BulkPricing implements PricingStrategy {
  calculate(base: number, qty: number) { return base * qty * (qty > 100 ? 0.85 : 1); }
}
class OrderPricer {
  constructor(private readonly strategy: PricingStrategy) {}
  price(base: number, qty: number) { return this.strategy.calculate(base, qty); }
}
```

**Red Flags:** caller owns algorithm selection via `if/else`; adding an algorithm requires editing existing code (Open/Closed violation); algorithm logic duplicated across callers.

**Refactoring link:** Replace Conditional with Polymorphism (`refactor-simplifying-conditionals`)

---

### 2. Observer *(critical for event architecture)*

**Intent:** When one object changes state, all dependents are notified automatically.

**Use when** event systems, pub/sub, or reactive pipelines need multiple independent components reflecting the same state. **Skip when** notification order must be guaranteed and cascading updates are hard to trace, or dependency set is small and static.

```typescript
interface Observer { update(event: string, payload: unknown): void; }
class EventEmitter {
  private listeners = new Map<string, Observer[]>();
  on(event: string, o: Observer)  { this.listeners.set(event, [...(this.listeners.get(event) ?? []), o]); }
  off(event: string, o: Observer) { this.listeners.set(event, (this.listeners.get(event) ?? []).filter(l => l !== o)); }
  emit(event: string, payload: unknown) { (this.listeners.get(event) ?? []).forEach(o => o.update(event, payload)); }
}
```

**Red Flags:** producer holds direct references to consumers; adding a consumer requires modifying the producer; events trigger cascading updates with unpredictable order.

---

### 3. State *(replaces state-conditional spaghetti)*

**Intent:** Allow an object to alter its behavior when its internal state changes.

**Use when** multiple methods share the same `switch (this.state)` block with enforced transitions. **Skip when** only 2 states with simple logic or transitions are unrestricted with no per-state behavior differences.

```typescript
interface TrafficLightState { next(): TrafficLightState; signal(): string; }
class GreenState  implements TrafficLightState { next() { return new YellowState(); } signal() { return 'GO';   } }
class YellowState implements TrafficLightState { next() { return new RedState();   } signal() { return 'SLOW'; } }
class RedState    implements TrafficLightState { next() { return new GreenState(); } signal() { return 'STOP'; } }

class TrafficLight {
  private state: TrafficLightState = new RedState();
  advance() { this.state = this.state.next(); }
  signal()  { return this.state.signal(); }
}
```

**Red Flags:** `switch (this.status)` repeated in 3+ methods; illegal state transitions possible; new state requires modifying every switch.

**Refactoring link:** Replace Type Code with State/Strategy (`refactor-simplifying-conditionals`)

---

### 4. Command *(enables undo/redo and operation queuing)*

**Intent:** Encapsulate a request as an object to support undo, queuing, logging, and parameterization.

**Use when** undo/redo, queuing, scheduling, or replay is needed. **Skip when** simple one-shot calls with no history or queuing — wrapping adds complexity with no benefit.

```typescript
interface Command { execute(): void; undo(): void; }
class InsertTextCommand implements Command {
  private prev = '';
  constructor(private readonly editor: { getText(): string; setText(v: string): void }, private readonly text: string) {}
  execute() { this.prev = this.editor.getText(); this.editor.setText(this.prev + this.text); }
  undo()    { this.editor.setText(this.prev); }
}
// History: Command[] — push on execute, pop().undo() on undo
```

**Red Flags:** undo by re-running operations in reverse; history stores raw strings instead of command objects; operations cannot be composed, delayed, or retried.

---

### 5. Template Method

**Intent:** Define algorithm skeleton in base class; subclasses override specific steps.

**Use when** several classes implement the same multi-step algorithm with 1-2 steps varying. **Skip when** the skeleton itself varies (use Strategy) or subclassing is too rigid (prefer composition).

```typescript
abstract class DataExporter {
  export(data: unknown[]): string {
    return this.wrap(this.format(this.validate(data)));
  }
  protected validate(data: unknown[]) { return data.filter(Boolean); }
  protected abstract format(data: unknown[]): string;
  protected wrap(content: string)     { return content; }
}
class CsvExporter extends DataExporter {
  protected format(data: unknown[]) { return data.map(r => Object.values(r as object).join(',')).join('\n'); }
}
```

**Red Flags:** same multi-step algorithm copy-pasted with 2 lines differing; subclass overrides entire method instead of the varying step; extension points undocumented.

**Refactoring link:** Pull Up Method, Extract Superclass (`refactor-generalization`)

---

### 6. Chain of Responsibility

**Intent:** Pass a request along a chain of handlers; each decides to process or pass on.

**Use when** multiple objects may handle a request determined at runtime (middleware, validation chains, approval workflows). **Skip when** exactly one handler always processes the request or unhandled requests must never silently slip through.

```typescript
abstract class ApprovalHandler {
  private next: ApprovalHandler | null = null;
  setNext(h: ApprovalHandler) { this.next = h; return h; }
  handle(amount: number): string { return this.next?.handle(amount) ?? 'No approver'; }
}
class TeamLeadApproval extends ApprovalHandler {
  handle(amount: number) { return amount <= 1000  ? 'Team Lead approved' : super.handle(amount); }
}
class ManagerApproval extends ApprovalHandler {
  handle(amount: number) { return amount <= 10000 ? 'Manager approved'   : super.handle(amount); }
}
```

**Red Flags:** hardcoded handler cascade in caller; order-dependent handlers without enforced order; no fallback — unmatched requests silently ignored.

---

### 7. Iterator

**Intent:** Provide sequential access to elements without exposing collection internals.

**Use when** custom collections (tree, graph, paginated results) need multiple traversal strategies. **Skip when** plain array/list with native iterators, or random access is required.

```typescript
class TreeNode<T> {
  constructor(readonly value: T, readonly children: TreeNode<T>[] = []) {}
}
function* depthFirst<T>(node: TreeNode<T>): Generator<T> {
  yield node.value;
  for (const child of node.children) yield* depthFirst(child);
}
```

**Red Flags:** caller accesses `collection.items[i]` directly; multiple callers implement their own traversal; collection exposes internal arrays solely for traversal.

---

### 8. Mediator

**Intent:** Central coordinator encapsulating how objects interact, preventing direct references.

**Use when** many-to-many coupling makes components hard to reuse (chat rooms, interconnected UI forms). **Skip when** few objects with simple interactions, or the mediator risks becoming a god object.

```typescript
interface Mediator { send(msg: string, sender: Colleague): void; }
class ChatRoom implements Mediator {
  private users: Colleague[] = [];
  register(u: Colleague) { this.users.push(u); }
  send(msg: string, sender: Colleague) { this.users.filter(u => u !== sender).forEach(u => u.receive(msg)); }
}
class Colleague {
  constructor(readonly name: string, private readonly room: Mediator) {}
  send(msg: string)    { this.room.send(msg, this); }
  receive(msg: string) { console.log(`${this.name}: ${msg}`); }
}
```

**Red Flags:** component holds direct references to many unrelated peers; adding a component requires modifying others; mediator owns business logic instead of just coordinating.

---

### 9. Memento

**Intent:** Capture and externalize an object's internal state for later restoration without violating encapsulation.

**Use when** undo/redo with private internals, snapshots, or transactional rollback. **Skip when** state is large (memory-intensive snapshots) or already public (encapsulation benefit is moot).

```typescript
class EditorMemento { constructor(private readonly state: string) {} getState() { return this.state; } }
class DocumentEditor {
  private content = '';
  write(text: string)                { this.content += text; }
  save(): EditorMemento              { return new EditorMemento(this.content); }
  restore(m: EditorMemento)          { this.content = m.getState(); }
  getContent()                       { return this.content; }
}
```

**Red Flags:** caller directly copies fields for undo; memento exposes setters; history contains live references instead of snapshots.

---

### 10. Visitor

**Intent:** Represent an operation on elements of a structure without modifying those classes.

**Use when** many unrelated operations on a stable hierarchy (AST traversal, compilers, renderers). **Skip when** element hierarchy changes frequently (every new type requires updating all visitors).

```typescript
interface ShapeVisitor { visitCircle(s: Circle): number; visitRect(s: Rect): number; }
interface Shape { accept(v: ShapeVisitor): number; }
class Circle implements Shape { constructor(readonly r: number) {} accept(v: ShapeVisitor) { return v.visitCircle(this); } }
class Rect   implements Shape { constructor(readonly w: number, readonly h: number) {} accept(v: ShapeVisitor) { return v.visitRect(this); } }
class AreaCalc implements ShapeVisitor {
  visitCircle(s: Circle) { return Math.PI * s.r ** 2; }
  visitRect(s: Rect)     { return s.w * s.h; }
}
```

**Red Flags:** new `instanceof` branch per operation; operation logic scattered across codebase; element classes accumulate unrelated methods.

---

### 11. Interpreter *(rarely applied)*

**Intent:** Define a grammar and interpreter for sentences in that language.

**Use when** simple, stable DSL or expression evaluator with small grammar. **Skip when** complex grammar (use ANTLR, PEG.js) or performance is critical.

```typescript
interface Expr { eval(ctx: Map<string, number>): number; }
class Num  implements Expr { constructor(private v: number) {} eval() { return this.v; } }
class Add  implements Expr {
  constructor(private l: Expr, private r: Expr) {}
  eval(ctx: Map<string, number>) { return this.l.eval(ctx) + this.r.eval(ctx); }
}
```

**Red Flags:** ad-hoc string parsing for a recurring mini-language; grammar rules duplicated in multiple parse functions; nested conditionals parsing tokens where a grammar hierarchy would be clearer.

---

## Decision Flowchart

```
COMMUNICATION or COORDINATION?
├── Multiple objects need notification of state changes?    → Observer
├── Save and restore internal state?                       → Memento
├── Object behavior changes based on internal state?       → State
├── Request passes through multiple potential handlers?    → Chain of Responsibility
├── Many-to-many coupling between objects?                 → Mediator
└── New operations on a stable class hierarchy?            → Visitor

ALGORITHMS or CONTROL FLOW?
├── Multiple interchangeable algorithms at runtime?        → Strategy
├── Algorithm skeleton fixed, but steps vary?              → Template Method
├── Actions must be stored, queued, or undone?             → Command
├── Traversing a complex collection uniformly?             → Iterator
└── Evaluating sentences in a simple grammar?              → Interpreter
```

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Strategy when a simple parameter suffices | Reserve for independently testable, swappable algorithms |
| Observer cascade — A triggers B triggers C | Keep chains shallow; use async queues for deep chains |
| State machine without enforced transitions | Encode valid transitions inside each State class |
| Command objects duplicating business logic | Command captures *what*; delegate *how* to domain model |
| Template Method when skeleton varies | Use Strategy + composition instead of inheritance |
| Mediator owning business logic | Mediator coordinates only — business rules stay in domain |
| Visitor on frequently-changing hierarchy | New elements force all visitors to change — keep ops on the class |
