---
name: refactor-generalization
description: Use when managing inheritance hierarchies, extracting shared behavior, deciding between inheritance and delegation, or dealing with Refused Bequest, Parallel Inheritance, or Speculative Generality smells
---

# Refactor: Dealing with Generalization

## Overview

These 12 techniques manage inheritance hierarchies — pulling shared behavior up, pushing specific behavior down, extracting common interfaces, and replacing inheritance with delegation (or vice versa). Correct generalization prevents code duplication across subclasses while avoiding over-engineering.

## When to Use

- Sibling classes share duplicate methods or fields
- Subclass only uses a fraction of parent's interface (Refused Bequest)
- Adding a subclass in one hierarchy requires adding one in another (Parallel Inheritance)
- Abstract class has only one concrete subclass (Speculative Generality)
- Inheritance is used for code reuse rather than true is-a relationships
- Multiple classes share a common interface but no shared implementation

## Quick Reference

| Technique | Problem | Solution |
|-----------|---------|----------|
| Pull Up Field | Duplicate field in sibling classes | Move field to superclass |
| Pull Up Method | Duplicate or similar method in sibling classes | Move method to superclass |
| Pull Up Constructor Body | Duplicate constructor code in subclasses | Move shared initialization to super constructor |
| Push Down Method | Method only relevant to one subclass | Move from parent to that subclass |
| Push Down Field | Field only used by one subclass | Move from parent to that subclass |
| Extract Subclass | Class has features used only in some instances | Create subclass for the special case |
| Extract Superclass | Two classes with similar features | Create parent class with shared features |
| Extract Interface | Multiple classes share a partial interface | Create interface for the shared protocol |
| Collapse Hierarchy | Subclass too similar to parent | Merge subclass into parent |
| Form Template Method | Sibling methods do same steps differently | Template method in parent, differing steps in subclasses |
| Replace Inheritance with Delegation | Subclass only uses part of parent, or is-a doesn't hold | Hold parent as a field, delegate specific methods |
| Replace Delegation with Inheritance | Class delegates most calls to another, and is truly a subtype | Use inheritance instead of delegation |

## Techniques in Detail

### 1. Pull Up Field / Pull Up Method

The most common generalization — eliminate duplication across sibling classes.

**Before:**
```typescript
class Salesman {
  readonly name: string;
  // ...
}

class Engineer {
  readonly name: string;
  // ...
}
```

**After:**
```typescript
class Employee {
  readonly name: string;
}

class Salesman extends Employee { /* ... */ }
class Engineer extends Employee { /* ... */ }
```

**Pull Up Method steps:**
1. Inspect methods in sibling classes for similarity
2. If method bodies are identical, move to parent
3. If signatures differ, rename to match first
4. If bodies differ slightly, use Extract Method to isolate differences, then Form Template Method
5. Run tests

### 2. Pull Up Constructor Body

**Before:**
```typescript
class Manager extends Employee {
  constructor(name: string, id: string, readonly grade: number) {
    super();
    this._name = name;
    this._id = id;
  }
}

class Engineer extends Employee {
  constructor(name: string, id: string, readonly specialty: string) {
    super();
    this._name = name;
    this._id = id;
  }
}
```

**After:**
```typescript
class Employee {
  constructor(
    protected readonly _name: string,
    protected readonly _id: string
  ) {}
}

class Manager extends Employee {
  constructor(name: string, id: string, readonly grade: number) {
    super(name, id);
  }
}

class Engineer extends Employee {
  constructor(name: string, id: string, readonly specialty: string) {
    super(name, id);
  }
}
```

### 3. Push Down Method / Push Down Field

The reverse of Pull Up — move things that only one subclass uses.

**Before:**
```typescript
class Employee {
  getQuota(): number { /* only relevant to Salesman */ }
}
```

**After:**
```typescript
class Salesman extends Employee {
  getQuota(): number { /* ... */ }
}
```

**When to push down:** When the feature doesn't apply to all subtypes and is causing Refused Bequest in other subclasses.

### 4. Extract Subclass

**Before:**
```typescript
class JobItem {
  getTotalPrice(): number {
    return this.unitPrice * this.quantity;
  }

  getUnitPrice(): number {
    return this.isLabor ? this.employee.rate : this.unitPrice;
  }
}
```

**After:**
```typescript
class JobItem {
  getTotalPrice(): number {
    return this.getUnitPrice() * this.quantity;
  }

  getUnitPrice(): number {
    return this.unitPrice;
  }
}

class LaborItem extends JobItem {
  getUnitPrice(): number {
    return this.employee.rate;
  }
}
```

### 5. Extract Superclass

When two existing classes share significant common features.

**Before:**
```typescript
class Department {
  getTotalAnnualCost(): number {
    return this.staff.reduce((sum, e) => sum + e.annualCost, 0);
  }
  getHeadCount(): number { return this.staff.length; }
  readonly name: string;
}

class Employee {
  getAnnualCost(): number { return this.monthlySalary * 12; }
  readonly name: string;
  readonly id: string;
}
```

**After:**
```typescript
abstract class Party {
  readonly name: string;
  abstract getAnnualCost(): number;
}

class Department extends Party {
  getAnnualCost(): number {
    return this.staff.reduce((sum, e) => sum + e.getAnnualCost(), 0);
  }
}

class Employee extends Party {
  getAnnualCost(): number { return this.monthlySalary * 12; }
}
```

### 6. Extract Interface

Less invasive than Extract Superclass — use when you only need the contract, not shared implementation.

```typescript
interface Billable {
  getRate(): number;
  hasSpecialSkill(): boolean;
}

class Employee implements Billable {
  getRate(): number { return this.monthlySalary; }
  hasSpecialSkill(): boolean { return this.certifications.length > 0; }
}

class Contractor implements Billable {
  getRate(): number { return this.hourlyRate * 160; }
  hasSpecialSkill(): boolean { return this.specializations.length > 0; }
}
```

**When to use Interface vs Superclass:**
- **Interface**: Classes share a contract but not implementation
- **Superclass**: Classes share both contract AND implementation

### 7. Collapse Hierarchy

When a subclass isn't different enough from its parent.

**Steps:**
1. Choose which class to remove (usually the subclass)
2. Pull Up or Push Down all fields and methods
3. Update all references to use the remaining class
4. Delete the empty class
5. Run tests

### 8. Form Template Method

When sibling methods follow the same algorithm but differ in specific steps.

**Before:**
```typescript
class TextStatement {
  value(customer: Customer): string {
    let result = header(customer);
    result += bodyText(customer);  // text-specific
    result += footer(customer);
    return result;
  }
}

class HtmlStatement {
  value(customer: Customer): string {
    let result = header(customer);
    result += bodyHtml(customer);  // html-specific
    result += footer(customer);
    return result;
  }
}
```

**After:**
```typescript
abstract class Statement {
  value(customer: Customer): string {
    let result = this.header(customer);
    result += this.body(customer);  // template method calls abstract step
    result += this.footer(customer);
    return result;
  }

  protected abstract body(customer: Customer): string;

  protected header(customer: Customer): string { /* shared */ }
  protected footer(customer: Customer): string { /* shared */ }
}

class TextStatement extends Statement {
  protected body(customer: Customer): string { /* text-specific */ }
}

class HtmlStatement extends Statement {
  protected body(customer: Customer): string { /* html-specific */ }
}
```

### 9. Replace Inheritance with Delegation

The most important technique here. Use when inheritance is being abused for code reuse rather than expressing a true "is-a" relationship.

**Before:**
```typescript
class Stack<T> extends Array<T> {
  push(item: T): number { return super.push(item); }
  pop(): T | undefined { return super.pop(); }
  // But Stack inherits sort, splice, slice, etc. — not appropriate!
}
```

**After:**
```typescript
class Stack<T> {
  private readonly items: T[] = [];

  push(item: T): Stack<T> {
    return Object.assign(new Stack<T>(), { items: [...this.items, item] });
  }

  pop(): { value: T | undefined; stack: Stack<T> } {
    const items = [...this.items];
    const value = items.pop();
    return { value, stack: Object.assign(new Stack<T>(), { items }) };
  }

  peek(): T | undefined {
    return this.items[this.items.length - 1];
  }
}
```

**Signals to use delegation:**
- Subclass only uses a few methods from parent
- Subclass overrides many parent methods to throw or no-op
- The "is-a" test fails: "Is a Stack an Array?" — not really
- You want to expose a restricted interface

### 10. Replace Delegation with Inheritance

The reverse — when delegation is excessive and the object truly IS the delegate type.

**When to apply:**
- You're delegating almost every method
- The object really is a specialized version of the delegate
- There's no need to restrict the interface

## Decision Flowchart

```dot
digraph generalization {
  rankdir=TB;
  start [label="Generalization\nproblem?" shape=diamond];
  q1 [label="Duplicate code\nin siblings?" shape=diamond];
  q2 [label="Subclass barely\nuses parent?" shape=diamond];
  q3 [label="Only one\nsubclass?" shape=diamond];
  q4 [label="Need shared\ncontract only?" shape=diamond];
  q5 [label="Siblings have same\nalgorithm, different\nsteps?" shape=diamond];

  pull [label="Pull Up\nField/Method" shape=box];
  rid [label="Replace Inheritance\nwith Delegation" shape=box];
  collapse [label="Collapse Hierarchy" shape=box];
  iface [label="Extract Interface" shape=box];
  superc [label="Extract Superclass" shape=box];
  template [label="Form Template\nMethod" shape=box];

  start -> q1;
  q1 -> pull [label="identical code"];
  q1 -> q5 [label="similar but\nnot identical"];
  q5 -> template [label="yes"];
  q5 -> q2 [label="no"];
  q1 -> q2 [label="no duplication"];
  q2 -> rid [label="yes"];
  q2 -> q3 [label="no"];
  q3 -> collapse [label="yes"];
  q3 -> q4 [label="no"];
  q4 -> iface [label="yes"];
  q4 -> superc [label="need shared\nimplementation too"];
}
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Pulling up methods that aren't truly shared | Only pull up when ALL subclasses need it — otherwise push down |
| Using inheritance for code reuse when "is-a" doesn't hold | Default to delegation; use inheritance only for true subtypes |
| Creating deep hierarchies (>3 levels) | Flatten with delegation or composition; prefer shallow hierarchies |
| Extracting superclass too early (only one known subclass) | Wait for the second case before generalizing (rule of three) |
| Form Template Method with too many abstract steps | If more than 3-4 steps differ, the algorithm isn't truly shared |
| Collapsing hierarchy when subclass has meaningful behavioral differences | Subclass should only be collapsed if it adds no unique behavior |
