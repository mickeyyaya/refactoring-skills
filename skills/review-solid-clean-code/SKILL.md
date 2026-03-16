---
name: review-solid-clean-code
description: Use when reviewing code for SOLID principle violations and clean code quality issues — covers all 5 SOLID principles (SRP, OCP, LSP, ISP, DIP) and core practices (DRY, KISS, YAGNI, Law of Demeter) with detection red flags and fix strategies
---

# Review: SOLID Principles and Clean Code

## When to Use

- Pull request review when code smells are present
- After detecting Bloater or Change Preventer smells (see `detect-code-smells`)
- A class or module is hard to test in isolation
- A change in one place forces changes in many others

---

## SOLID Principles

### SRP -- Single Responsibility Principle

One class = one reason to change.

**Red Flags:** Class name contains "Manager"/"Utils", 10+ public methods spanning unrelated domains, unrelated imports.

```typescript
// Violation: persistence, formatting, and email in one class
class UserManager {
  save(user: User): void { /* DB write */ }
  formatReport(user: User): string { /* HTML formatting */ }
  sendWelcomeEmail(user: User): void { /* SMTP call */ }
}
```

**Fix:** Extract Class -> `UserRepository`, `UserReportFormatter`, `UserEmailService`. See `refactor-moving-features`.

---

### OCP -- Open/Closed Principle

Open for extension, closed for modification.

**Red Flags:** `switch`/`if-else` chain on type tag that grows with each new type, adding features requires editing existing tested classes.

```typescript
// Violation: every new shape requires modifying this function
function area(shape: Shape): number {
  if (shape.type === "circle") return Math.PI * shape.radius ** 2;
  if (shape.type === "square") return shape.side ** 2;
}
```

**Fix:** Interface with polymorphism (`Shape.area()`). See `refactor-simplifying-conditionals`, `design-patterns-behavioral` (Strategy).

---

### LSP -- Liskov Substitution Principle

Subtypes must be substitutable for their base types without altering correctness.

**Red Flags:** Subclass overrides with `NotImplemented`, `instanceof` checks in business logic, subclass narrows preconditions.

```typescript
// Violation: Square breaks Rectangle contract
class Square extends Rectangle {
  setWidth(w: number): void { this.width = w; this.height = w; }
}

// Violation: instanceof checks
function process(animal: Animal): void {
  if (animal instanceof Dog) { /* dog-specific */ }
}
```

**Fix:** Replace Inheritance with Delegation or restructure hierarchy. See `refactor-generalization`.

---

### ISP -- Interface Segregation Principle

Clients should not depend on interfaces they don't use.

**Red Flags:** Implementations that throw `"Not supported"`, class implements interface but uses only 2 of 8 methods.

```typescript
// Violation: robots don't eat or sleep
class RobotWorker implements Worker {
  work(): void { /* real */ }
  eat(): void { throw new Error("Not supported"); }
  sleep(): void { throw new Error("Not supported"); }
}
```

**Fix:** Split into `Workable`, `Feedable`, `Restable`. See `refactor-generalization` (Extract Interface).

---

### DIP -- Dependency Inversion Principle

High-level modules depend on abstractions, not concrete implementations.

**Red Flags:** `new ConcreteService()` in business logic, tests require real databases/HTTP, swapping implementations requires editing business logic.

```typescript
// Violation                          // Fixed
class OrderService {                  class OrderService {
  private repo = new MySQLRepo();       constructor(private readonly repo: OrderRepository) {}
  placeOrder(order: Order): void {      placeOrder(order: Order): void {
    this.repo.save(order);                this.repo.save(order); // testable with mock
  }                                     }
}                                     }
```

**Fix:** Introduce abstraction interface, inject via constructor. See `design-patterns-creational-structural` (Factory, DI).

---

## Clean Code Practices

### DRY -- Don't Repeat Yourself

**Red Flags:** Identical code blocks in multiple files, same validation in 3+ places, same business rule in frontend and backend.

**Fix:** Extract Method/Class for code duplication. For knowledge duplication, identify canonical owner and delegate. See `refactor-composing-methods`.

### KISS -- Keep It Simple

**Red Flags:** 5-level class hierarchy for a map-solvable problem, design patterns where a plain function suffices.

**Fix:** Ask "what is the simplest change that works?" Collapse unnecessary layers. See `refactor-composing-methods` (Substitute Algorithm).

### YAGNI -- You Aren't Gonna Need It

**Red Flags:** Abstract classes with one implementation, feature flags never enabled, parameters always passed as `null`.

**Fix:** Delete unused code. Git history preserves it if needed later. See `refactor-generalization` (Collapse Hierarchy).

### Law of Demeter

**Red Flags:** `a.getB().getC().doSomething()`, business logic knowing remote object internals.

**Fix:** Add method on intermediate object (`order.getCustomerCity()`). See `refactor-moving-features` (Hide Delegate).

---

## Review Checklist

### SOLID

- [ ] **SRP** -- Each class has a single, clearly named responsibility
- [ ] **OCP** -- New behavior added via new classes, not modifying existing ones
- [ ] **LSP** -- Subclasses honor parent contract. No `instanceof` or `NotImplemented`
- [ ] **ISP** -- Interfaces are focused. No unsupported-method errors
- [ ] **DIP** -- Business logic depends on abstractions. Concrete types injected

### Clean Code

- [ ] **DRY** -- No duplicated business rules or copy-pasted logic
- [ ] **KISS** -- Simplest correct solution. No premature abstractions
- [ ] **YAGNI** -- No unused parameters, dead code, or speculative features
- [ ] **Demeter** -- No chains longer than 2 levels

### General Quality

- [ ] Functions under 20 lines (see `refactor-composing-methods`)
- [ ] Files under 400 lines
- [ ] No mutation of parameters
- [ ] Error cases explicitly handled
- [ ] New code has corresponding unit tests

---

## Violations at a Glance

| Principle | Fastest Red Flag | Primary Fix |
|-----------|-----------------|-------------|
| SRP | Class name has "And" or "Manager" | Extract Class |
| OCP | `switch (type)` on a growing enum | Strategy pattern |
| LSP | `instanceof` check in caller | Replace Inheritance with Delegation |
| ISP | `throw new Error("Not supported")` | Extract Interface |
| DIP | `new ConcreteClass()` in business logic | Constructor injection |
| DRY | Identical logic blocks in 2+ files | Extract Method / Extract Class |
| KISS | Multi-level hierarchy for simple lookup | Collapse / simplify |
| YAGNI | Parameter always passed as `null` | Remove parameter |
| Demeter | `a.getB().getC().doSomething()` | Hide Delegate |

---

## Cross-References

| Topic | Related Skill |
|-------|--------------|
| Detecting code smells that signal violations | `detect-code-smells` |
| Extract Method, Extract Variable, Remove Assignments to Parameters | `refactor-composing-methods` |
| Extract Class, Move Method, Hide Delegate | `refactor-moving-features` |
| Extract Interface, Replace Inheritance with Delegation | `refactor-generalization` |
| Strategy (OCP fix), Factory (DIP fix) | `design-patterns-behavioral`, `design-patterns-creational-structural` |
