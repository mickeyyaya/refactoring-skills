---
name: design-patterns-behavioral
description: Use when reviewing code for communication and responsibility problems between objects — covers all 11 GoF Behavioral patterns with intent, red flags, and refactoring cross-references
---

# Design Patterns: Behavioral

## Overview

Behavioral patterns address how objects communicate and distribute responsibility. They replace tangled conditional logic, tight coupling between collaborators, and ad-hoc event wiring with well-named structures the entire team can reason about. Recognizing which pattern is — or should be — present is a core code review skill.

## When to Use

- Reviewing code with large `switch`/`if-else` blocks that branch on type or state
- Identifying tightly coupled objects that call each other in every direction
- Noticing duplicated algorithm logic with only small steps varying
- Evaluating event and notification systems for correctness and scalability
- Recommending a named pattern so the team shares vocabulary for the change

## Quick Reference

| Pattern | Core Problem Solved | Key Red Flag |
|---------|---------------------|--------------|
| Chain of Responsibility | Decouple sender from receiver; multiple handlers possible | Hardcoded handler cascade in caller |
| Command | Encapsulate request as object; supports undo/queue | Method calls not storable or reversible |
| Iterator | Uniform traversal without exposing collection internals | Callers access internal array fields directly |
| Mediator | Replace many-to-many coupling with a central coordinator | Objects holding direct references to many unrelated peers |
| Memento | Save and restore state without breaking encapsulation | Caller copies internal fields to implement undo |
| Observer | Notify dependents of state changes automatically | Producer manually calls every consumer after each change |
| State | Object changes behavior as internal state changes | Giant `switch (this.state)` repeated in multiple methods |
| Strategy | Make algorithms interchangeable at runtime | `if (type === 'A') algoA() else if (type === 'B') algoB()` |
| Template Method | Fix algorithm structure; let subclasses override steps | Copy-pasted algorithm with one or two lines differing |
| Visitor | Add operations to a class hierarchy without modifying it | New `instanceof` branch added for every new operation |
| Interpreter | Evaluate sentences in a simple grammar | Ad-hoc string parsing scattered across the codebase |

---

## Behavioral Patterns

### 1. Strategy *(most commonly applied)*

**Intent:** Define a family of algorithms, encapsulate each one, and make them interchangeable.

**When to Use:** Multiple ways to perform a task, chosen at runtime; you want to eliminate `if/else` algorithm selection; each algorithm should be unit-testable in isolation.

**When NOT to Use:** Only one algorithm exists and will never change. A single boolean flag — use a parameter instead.

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

**Code Review Red Flags**
- `if (strategy === 'discount') applyDiscount() else if (strategy === 'bulk') applyBulk()` — caller owns selection
- Adding a new algorithm requires editing existing code (Open/Closed violation)
- Algorithm logic duplicated across callers with minor differences

**Refactoring link:** Replace Conditional with Polymorphism (`refactor-simplifying-conditionals`)

---

### 2. Observer *(critical for event architecture)*

**Intent:** When one object changes state, all its dependents are notified and updated automatically.

**When to Use:** Event systems, pub/sub, reactive data pipelines; multiple independent components reflect the same model state.

**When NOT to Use:** Notification order must be guaranteed and cascading updates are hard to trace. Small and static dependency set — direct calls are clearer.

```typescript
interface Observer { update(event: string, payload: unknown): void; }
class EventEmitter {
  private listeners = new Map<string, Observer[]>();
  on(event: string, o: Observer)  { this.listeners.set(event, [...(this.listeners.get(event) ?? []), o]); }
  off(event: string, o: Observer) { this.listeners.set(event, (this.listeners.get(event) ?? []).filter(l => l !== o)); }
  emit(event: string, payload: unknown) { (this.listeners.get(event) ?? []).forEach(o => o.update(event, payload)); }
}
```

**Code Review Red Flags**
- Producer holds direct references to consumers and calls them explicitly
- Adding a new consumer requires modifying the producer
- Events trigger cascading updates with unpredictable order

---

### 3. State *(replaces state-conditional spaghetti)*

**Intent:** Allow an object to alter its behavior when its internal state changes.

**When to Use:** Multiple methods share the same `switch (this.state)` block; state transitions have rules; object appears to change class at runtime.

**When NOT to Use:** Only 2 states with simple logic — a boolean flag is fine. Transitions are unrestricted with no per-state behavior differences.

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

**Code Review Red Flags**
- `switch (this.status)` repeated identically across 3+ methods
- Illegal state transitions are possible because validation is missing
- New state requires modifying every switch statement in the class

**Refactoring link:** Replace Type Code with State/Strategy (`refactor-simplifying-conditionals`)

---

### 4. Command *(enables undo/redo and operation queuing)*

**Intent:** Encapsulate a request as an object to support undo, queuing, logging, and parameterization.

**When to Use:** Undo/redo required; operations must be queued, scheduled, or replayed; macro system or audit log needed.

**When NOT to Use:** Simple one-shot calls with no history or queuing needed — wrapping adds complexity with no benefit.

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

**Code Review Red Flags**
- Undo implemented by caller re-running operations in reverse — brittle
- History array stores raw strings instead of executable command objects
- Operations cannot be composed, delayed, or retried

---

### 5. Template Method

**Intent:** Define the skeleton of an algorithm in a base class; subclasses override specific steps without changing the sequence.

**When to Use:** Several classes implement the same multi-step algorithm with only 1-2 steps varying; framework hooks for callers to extend.

**When NOT to Use:** The algorithm skeleton itself varies — use Strategy. Subclassing is too rigid — prefer composition.

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

**Code Review Red Flags**
- Same multi-step algorithm copy-pasted across sibling classes with 2 lines differing
- Subclass overrides the entire method instead of just the varying step
- Extension points (abstract/hook methods) are not documented

**Refactoring link:** Pull Up Method, Extract Superclass (`refactor-generalization`)

---

### 6. Chain of Responsibility

**Intent:** Pass a request along a chain of handlers; each handler decides to process it or pass it on.

**When to Use:** Multiple objects may handle a request; handler is determined at runtime; middleware pipelines, validation chains, approval workflows.

**When NOT to Use:** Exactly one handler always processes the request — use a direct call. An unhandled request must never silently slip through.

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

**Code Review Red Flags**
- Hardcoded handler cascade in the caller (`if (a.canHandle()) a.handle() else if (b.canHandle())...`)
- Handlers are order-dependent but the order is not enforced
- No fallback handler — unmatched requests are silently ignored

---

### 7. Iterator

**Intent:** Provide sequential access to elements of a collection without exposing its internal structure.

**When to Use:** Custom or complex collections (tree, graph, paginated results); multiple traversal strategies for the same collection.

**When NOT to Use:** Plain array/list — native iterators already exist. Random access is required — iterators are sequential.

```typescript
class TreeNode<T> {
  constructor(readonly value: T, readonly children: TreeNode<T>[] = []) {}
}
function* depthFirst<T>(node: TreeNode<T>): Generator<T> {
  yield node.value;
  for (const child of node.children) yield* depthFirst(child);
}
```

**Code Review Red Flags**
- Caller accesses `collection.items[i]` directly — breaks encapsulation
- Multiple callers each implement their own traversal logic for the same collection
- Collection exposes internal array fields solely for traversal

---

### 8. Mediator

**Intent:** Define a central coordinator that encapsulates how a set of objects interact, preventing them from referring to each other explicitly.

**When to Use:** Many-to-many coupling between objects; components are hard to reuse because they reference too many peers; chat rooms, interconnected UI forms.

**When NOT to Use:** Few objects with simple directional interactions — mediator becomes over-engineered. The mediator itself grows into a god object.

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

**Code Review Red Flags**
- Component holds direct references to many unrelated peers
- Adding a new component requires modifying every other component
- Mediator owns business logic instead of just coordinating communication

---

### 9. Memento

**Intent:** Capture and externalize an object's internal state without violating encapsulation, so it can be restored later.

**When to Use:** Undo/redo where the originator's internals must stay private; snapshots, checkpoints, transactional rollback.

**When NOT to Use:** State is large and snapshots would be memory-intensive. Object state is already public — Memento's encapsulation benefit is moot.

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

**Code Review Red Flags**
- Caller directly copies fields from the object to implement undo — breaks encapsulation
- Memento objects expose setters — saved state can be tampered with
- History list contains live object references (not snapshots), so past states mutate

---

### 10. Visitor

**Intent:** Represent an operation to be performed on elements of an object structure without modifying those classes.

**When to Use:** Many unrelated operations on a stable class hierarchy; adding operations without polluting element classes; AST traversal, compilers, document renderers.

**When NOT to Use:** The element hierarchy changes frequently — every new element type requires updating all visitors. Operations are few and tightly related to the elements.

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

**Code Review Red Flags**
- New `instanceof` branch added for every new operation on the class hierarchy
- Operation logic for multiple element types scattered across the codebase
- Element classes accumulate unrelated methods for different cross-cutting operations

---

### 11. Interpreter *(rarely applied in practice)*

**Intent:** Define a grammar and an interpreter to evaluate sentences in that language.

**When to Use:** Simple, stable DSL or expression evaluator; grammar is small enough to represent as a class hierarchy.

**When NOT to Use:** Complex grammar — use a proper parser generator (ANTLR, PEG.js). Performance is critical — tree-walking interpreters are slow.

```typescript
interface Expr { eval(ctx: Map<string, number>): number; }
class Num  implements Expr { constructor(private v: number) {} eval() { return this.v; } }
class Add  implements Expr {
  constructor(private l: Expr, private r: Expr) {}
  eval(ctx: Map<string, number>) { return this.l.eval(ctx) + this.r.eval(ctx); }
}
```

**Code Review Red Flags**
- Ad-hoc string parsing for a recurring mini-language scattered across the codebase
- Grammar rules duplicated in multiple parse functions
- Nested conditionals parsing tokens by hand where a grammar class hierarchy would be clearer

---

## Decision Flowchart

```
Is the problem about COMMUNICATION or COORDINATION?
├── Multiple objects need notification of state changes?    → Observer
├── Save and restore internal state?                       → Memento
├── Object behavior changes based on internal state?       → State
├── Request passes through multiple potential handlers?    → Chain of Responsibility
├── Many-to-many coupling between objects?                 → Mediator
└── New operations needed on a stable class hierarchy?     → Visitor

Is the problem about ALGORITHMS or CONTROL FLOW?
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
| Using Strategy when a simple parameter suffices | Reserve Strategy for independently unit-testable, swappable algorithms |
| Observer cascade — A triggers B triggers C | Keep chains shallow; document update order; use async queues for deep chains |
| State machine without enforced transitions | Encode valid transitions inside each State class, not in the caller |
| Command objects duplicating business logic | Command captures *what* to do; delegate *how* to the domain model |
| Template Method when the skeleton itself varies | If the sequence changes, use Strategy + composition instead of inheritance |
| Mediator owning business logic | Mediator coordinates communication only — business rules stay in the domain |
| Visitor on a frequently-changing element hierarchy | New element types force all visitors to change — keep operations on the class instead |
