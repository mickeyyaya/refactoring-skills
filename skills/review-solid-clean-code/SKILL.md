---
name: review-solid-clean-code
description: Use when reviewing code for SOLID principle violations and clean code quality issues — covers all 5 SOLID principles (SRP, OCP, LSP, ISP, DIP) and core practices (DRY, KISS, YAGNI, Law of Demeter) with detection red flags and fix strategies
---

# Review: SOLID Principles and Clean Code

## Overview

This skill guides code review through a structured lens of SOLID principles and clean code practices. Each section follows the same pattern: what the principle means, what violations look like, red flags to scan for in a review, and the fix strategy to recommend.

## When to Use

- During pull request review when code smells are present
- After detecting Bloater or Change Preventer smells (see `detect-code-smells`)
- When a class or module is hard to test in isolation
- When a change in one place forces changes in many others
- When onboarding new contributors who need a review checklist

---

## SOLID Principles

### 1. SRP — Single Responsibility Principle

**Definition:** A class should have only one reason to change. One class = one actor = one responsibility.

**Violation Symptoms:**
- Class name contains "And", "Or", "Manager", "Handler", "Helper", "Utils"
- Class has 10+ public methods spanning unrelated domains
- A change to one feature forces re-testing an entirely unrelated feature
- The class has many unrelated imports

**Review Red Flags:**
```typescript
// Red flag: one class handles persistence, formatting, and email
class UserManager {
  save(user: User): void { /* DB write */ }
  formatReport(user: User): string { /* HTML formatting */ }
  sendWelcomeEmail(user: User): void { /* SMTP call */ }
}
```

**Fix Strategy:** Extract Class — split into `UserRepository`, `UserReportFormatter`, `UserEmailService`. Cross-reference: `refactor-moving-features` → Move Method / Extract Class.

---

### 2. OCP — Open/Closed Principle

**Definition:** Software entities should be open for extension but closed for modification. Add new behavior by adding new code, not by changing existing code.

**Violation Symptoms:**
- A `switch` or `if/else if` chain on a type tag that must grow with every new type
- Adding a new feature requires editing an existing, tested class
- Core logic files are frequently touched in unrelated PRs

**Review Red Flags:**
```typescript
// Red flag: every new shape requires modifying this function
function area(shape: Shape): number {
  if (shape.type === "circle") return Math.PI * shape.radius ** 2;
  if (shape.type === "square") return shape.side ** 2;
  // new shape requires editing here
}
```

**Fix Strategy:** Apply the Strategy pattern or polymorphism. Define an interface (`Shape.area()`) and let each concrete type implement it. New shapes extend without touching existing code. Cross-reference: `design-patterns-behavioral` → Strategy; `design-patterns-creational-structural` → Factory Method.

---

### 3. LSP — Liskov Substitution Principle

**Definition:** Subtypes must be fully substitutable for their base types without altering the correctness of the program. A caller using the base type must not need to know which subtype it has.

**Violation Symptoms:**
- A subclass overrides a method to throw `NotImplemented` or `UnsupportedOperation`
- Caller code contains `instanceof` checks to adjust behavior per subtype
- A subclass narrows preconditions or widens postconditions of the parent

**Review Red Flags:**
```typescript
// Red flag: Square narrows Rectangle's contract
class Rectangle {
  setWidth(w: number): void { this.width = w; }
  setHeight(h: number): void { this.height = h; }
}
class Square extends Rectangle {
  setWidth(w: number): void { this.width = w; this.height = w; } // breaks Rectangle contract
  setHeight(h: number): void { this.width = h; this.height = h; }
}

// Red flag: instanceof checks signal LSP violation
function process(animal: Animal): void {
  if (animal instanceof Dog) { /* dog-specific */ }
  if (animal instanceof Cat) { /* cat-specific */ }
}
```

**Fix Strategy:** Replace Inheritance with Delegation or restructure the hierarchy so each subtype truly IS-A base type. Cross-reference: `refactor-generalization` → Replace Inheritance with Delegation.

---

### 4. ISP — Interface Segregation Principle

**Definition:** Clients should not be forced to depend on interfaces they do not use. Prefer many small, focused interfaces over one large general-purpose interface.

**Violation Symptoms:**
- An interface has methods that some implementations leave empty or throw errors
- A class implements an interface but only uses 2 of its 8 methods
- Changing an unused method in an interface forces recompilation or changes across unrelated classes

**Review Red Flags:**
```typescript
// Red flag: fat interface forces irrelevant implementations
interface Worker {
  work(): void;
  eat(): void;    // robots don't eat
  sleep(): void;  // robots don't sleep
}

class RobotWorker implements Worker {
  work(): void { /* real implementation */ }
  eat(): void { throw new Error("Not supported"); }   // ISP violation
  sleep(): void { throw new Error("Not supported"); } // ISP violation
}
```

**Fix Strategy:** Extract Interface — split into `Workable`, `Feedable`, `Restable`. Let classes implement only the interfaces relevant to them. Cross-reference: `refactor-generalization` → Extract Interface.

---

### 5. DIP — Dependency Inversion Principle

**Definition:** High-level modules should not depend on low-level modules. Both should depend on abstractions. Abstractions should not depend on details; details should depend on abstractions.

**Violation Symptoms:**
- Business logic instantiates concrete classes with `new ConcreteService()`
- No dependency injection — dependencies are hardcoded inside constructors or methods
- Unit tests require real databases, HTTP clients, or file systems to run
- Swapping an implementation requires editing the business logic file

**Review Red Flags:**
```typescript
// Red flag: high-level OrderService depends on concrete MySQLRepository
class OrderService {
  private repo = new MySQLOrderRepository(); // hardcoded concrete

  placeOrder(order: Order): void {
    this.repo.save(order); // impossible to test without MySQL
  }
}
```

**Fix Strategy:** Introduce an abstraction (`OrderRepository` interface) and inject the concrete implementation via the constructor. Cross-reference: `design-patterns-creational-structural` → Factory, Abstract Factory; use DI containers when the framework supports it.

```typescript
// Fixed: depend on abstraction, inject concrete
class OrderService {
  constructor(private readonly repo: OrderRepository) {}

  placeOrder(order: Order): void {
    this.repo.save(order); // testable with a mock
  }
}
```

---

## Clean Code Practices

### DRY — Don't Repeat Yourself

**Definition:** Every piece of knowledge should have a single, authoritative representation in the system. Duplication is not just copy-paste — it is also parallel data structures, divergent API wrappers, and repeated business rules scattered across modules.

**Violation Symptoms:**
- Identical or near-identical code blocks in multiple files
- The same validation rule implemented in 3 different places
- Multiple functions that do the same thing but with slightly different variable names

**Review Red Flags:** Scan for copy-paste code, near-duplicate test helpers, and business rules that exist in both the frontend and backend without a shared source of truth.

**Fix Strategy:** Extract Method / Extract Class for code duplication. For knowledge duplication (e.g., a business rule), identify the canonical owner and have all others delegate to it. Cross-reference: `refactor-composing-methods` → Extract Method.

---

### KISS — Keep It Simple

**Definition:** Prefer the simplest solution that correctly solves the problem. Complexity is a liability — every additional abstraction must earn its place.

**Violation Symptoms:**
- A 5-level class hierarchy for a problem that could use a map
- Generics, abstractions, or design patterns applied where a plain function would suffice
- Code that is difficult to explain to a junior developer in one sentence

**Review Red Flags:** Over-engineered abstractions, premature generalization, excessive configuration objects for simple behaviors.

**Fix Strategy:** Ask "What is the simplest change that makes this work?" Collapse unnecessary layers. Cross-reference: `refactor-composing-methods` → Substitute Algorithm (replace complex algorithm with simpler one).

---

### YAGNI — You Aren't Gonna Need It

**Definition:** Do not add functionality until it is necessary. Build for today's requirements, not hypothetical future ones.

**Violation Symptoms:**
- Unused configuration parameters "for future extensibility"
- Abstract base classes with only one concrete implementation
- Feature flags that wrap code never enabled in production
- Method parameters that are always passed as `null` or ignored

**Review Red Flags:** Code that exists to handle cases that "might come up someday." Ask: is this used in a real test or production flow today?

**Fix Strategy:** Delete unused code. If it might be needed later, it will be in git history. Cross-reference: `refactor-generalization` → Collapse Hierarchy (when premature abstractions exist).

---

### Law of Demeter — Principle of Least Knowledge

**Definition:** A method should only call methods on: itself, its parameters, objects it creates, and its direct component objects. Do not reach through chains of objects.

**Violation Symptoms:**
- Method chains like `a.getB().getC().doSomething()`
- Business logic that knows the internal structure of remote objects
- Changes in a distant object's internals cascade through many files

**Review Red Flags:**
```typescript
// Red flag: OrderService knows too much about customer internals
class OrderService {
  notify(order: Order): void {
    const city = order.getCustomer().getAddress().getCity(); // chain!
    mailer.send(city);
  }
}
```

**Fix Strategy:** Add a method to the intermediate object that provides what the caller actually needs (`order.getCustomerCity()`), hiding the internal chain. Cross-reference: `refactor-moving-features` → Hide Delegate.

---

## Review Checklist

Use this checklist during pull request review. Mark each item PASS / FAIL / N/A.

### SOLID

- [ ] **SRP** — Each class has a single, clearly named responsibility. No "Manager" or "Utils" doing multiple jobs.
- [ ] **OCP** — New behavior is added via new classes/functions, not by modifying existing ones. No open `switch` on type tags.
- [ ] **LSP** — Subclasses honor the contract of their parent. No `instanceof` in business logic. No `NotImplemented` overrides.
- [ ] **ISP** — Interfaces are focused. No implementation throws errors for methods it doesn't support.
- [ ] **DIP** — Business logic depends on abstractions. Concrete types are injected, not instantiated inline.

### Clean Code

- [ ] **DRY** — No duplicated business rules or copy-pasted logic blocks. Each concept has one home.
- [ ] **KISS** — The simplest correct solution is used. No premature abstractions or unnecessary generics.
- [ ] **YAGNI** — No unused parameters, dead code, or "future-proof" features without active use.
- [ ] **Demeter** — No method chains longer than 2 levels. Caller does not reach into the internals of strangers.

### General Quality

- [ ] Functions are under 20 lines (see `refactor-composing-methods` if not)
- [ ] Files are under 400 lines
- [ ] No mutation of parameters (see `refactor-composing-methods` → Remove Assignments to Parameters)
- [ ] Error cases are explicitly handled — no silent swallows
- [ ] New code has corresponding unit tests

---

## Common Violations at a Glance

| Principle | Fastest Red Flag | Primary Fix |
|-----------|-----------------|-------------|
| SRP | Class name has "And" or "Manager" | Extract Class |
| OCP | `switch (type)` on a growing enum | Strategy pattern |
| LSP | `instanceof` check in caller | Replace Inheritance with Delegation |
| ISP | `throw new Error("Not supported")` in interface impl | Extract Interface |
| DIP | `new ConcreteClass()` in business logic | Constructor injection |
| DRY | Identical logic blocks in 2+ files | Extract Method / Extract Class |
| KISS | Multi-level hierarchy for a simple lookup | Collapse / simplify |
| YAGNI | Parameter always passed as `null` | Remove parameter |
| Demeter | `a.getB().getC().doSomething()` | Hide Delegate |

---

## Cross-References

| Topic | Related Skill |
|-------|--------------|
| Detecting the code smells that signal violations | `detect-code-smells` |
| Extract Method, Extract Variable, Remove Assignments to Parameters | `refactor-composing-methods` |
| Extract Class, Move Method, Hide Delegate | `refactor-moving-features` |
| Extract Interface, Replace Inheritance with Delegation, Collapse Hierarchy | `refactor-generalization` |
| Strategy pattern (OCP fix), Factory / Abstract Factory (DIP fix) | `design-patterns-behavioral`, `design-patterns-creational-structural` |
