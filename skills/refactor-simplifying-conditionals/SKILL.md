---
name: refactor-simplifying-conditionals
description: Use when conditional logic is complex, nested, duplicated, or uses type codes instead of polymorphism — covers Decompose Conditional, Guard Clauses, Replace Conditional with Polymorphism, and 5 more techniques
---

# Refactor: Simplifying Conditional Expressions

## Overview

These 8 techniques flatten, clarify, and eliminate conditional logic. Complex conditionals are one of the biggest sources of bugs and confusion. The goal: make each branch's purpose obvious, eliminate duplication across branches, and replace type-switching with polymorphism.

## When to Use

- Nested if/else chains deeper than 2 levels
- Same condition checked in multiple places
- Switch statements on type codes that grow with each new type
- Conditional with complex boolean expressions
- Null checks scattered throughout the code
- Methods with early returns mixed with deep logic

## Quick Reference

| Technique | Problem | Solution |
|-----------|---------|----------|
| Decompose Conditional | Complex condition with big then/else blocks | Extract condition and branches into named methods |
| Consolidate Conditional Expression | Multiple conditions with same result | Combine into single condition with descriptive name |
| Consolidate Duplicate Conditional Fragments | Same code in every branch | Move shared code outside the conditional |
| Remove Control Flag | Boolean variable controls loop flow | Use `break`, `return`, or `continue` instead |
| Replace Nested Conditionals with Guard Clauses | Deep nesting from special-case checks | Handle edge cases early with `return`, leave happy path unindented |
| Replace Conditional with Polymorphism | Switch on type drives different behavior | Create subclass or strategy per type |
| Introduce Null Object | Null checks repeated before using an object | Create a Null/Default implementation that does nothing |
| Introduce Assertion | Code assumes a condition but doesn't check it | Add explicit assertion to document and enforce the assumption |

## Techniques in Detail

### 1. Decompose Conditional

**Before:**
```typescript
function calculateCharge(date: Date, quantity: number, plan: Plan): number {
  if (date.getMonth() >= 6 && date.getMonth() <= 8) {
    return quantity * plan.summerRate + plan.summerServiceCharge;
  } else {
    return quantity * plan.regularRate + plan.regularServiceCharge;
  }
}
```

**After:**
```typescript
function calculateCharge(date: Date, quantity: number, plan: Plan): number {
  if (isSummer(date)) {
    return summerCharge(quantity, plan);
  }
  return regularCharge(quantity, plan);
}

function isSummer(date: Date): boolean {
  return date.getMonth() >= 6 && date.getMonth() <= 8;
}

function summerCharge(quantity: number, plan: Plan): number {
  return quantity * plan.summerRate + plan.summerServiceCharge;
}

function regularCharge(quantity: number, plan: Plan): number {
  return quantity * plan.regularRate + plan.regularServiceCharge;
}
```

### 2. Consolidate Conditional Expression

**Before:**
```typescript
function disabilityAmount(employee: Employee): number {
  if (employee.seniority < 2) return 0;
  if (employee.monthsDisabled > 12) return 0;
  if (employee.isPartTime) return 0;
  // compute disability amount...
}
```

**After:**
```typescript
function disabilityAmount(employee: Employee): number {
  if (isNotEligibleForDisability(employee)) return 0;
  // compute disability amount...
}

function isNotEligibleForDisability(employee: Employee): boolean {
  return employee.seniority < 2
    || employee.monthsDisabled > 12
    || employee.isPartTime;
}
```

### 3. Consolidate Duplicate Conditional Fragments

**Before:**
```typescript
if (isSpecialDeal) {
  total = price * 0.95;
  send();
} else {
  total = price * 0.98;
  send();
}
```

**After:**
```typescript
total = isSpecialDeal ? price * 0.95 : price * 0.98;
send();
```

### 4. Remove Control Flag

**Before:**
```typescript
function checkSecurity(people: string[]): string {
  let found = false;
  let result = "";
  for (const person of people) {
    if (!found) {
      if (person === "Don" || person === "John") {
        result = person;
        found = true;
      }
    }
  }
  return result;
}
```

**After:**
```typescript
function checkSecurity(people: string[]): string {
  for (const person of people) {
    if (person === "Don" || person === "John") {
      return person;
    }
  }
  return "";
}
```

### 5. Replace Nested Conditionals with Guard Clauses

One of the most impactful simplifications. Guard clauses handle edge cases early so the main logic stays flat.

**Before:**
```typescript
function getPayAmount(employee: Employee): number {
  if (employee.isSeparated) {
    return separatedAmount();
  } else {
    if (employee.isRetired) {
      return retiredAmount();
    } else {
      // compute normal pay...
      return normalPayAmount();
    }
  }
}
```

**After:**
```typescript
function getPayAmount(employee: Employee): number {
  if (employee.isSeparated) return separatedAmount();
  if (employee.isRetired) return retiredAmount();
  return normalPayAmount();
}
```

**Rule of thumb:** If both branches are part of normal behavior, use if/else. If one branch is a special case, use a guard clause (early return).

### 6. Replace Conditional with Polymorphism

The most powerful technique — eliminates switch statements that grow with each new type.

**Before:**
```typescript
function calculateArea(shape: Shape): number {
  switch (shape.type) {
    case "circle":
      return Math.PI * shape.radius ** 2;
    case "rectangle":
      return shape.width * shape.height;
    case "triangle":
      return (shape.base * shape.height) / 2;
    default:
      throw new Error(`Unknown shape: ${shape.type}`);
  }
}
```

**After:**
```typescript
interface Shape {
  calculateArea(): number;
}

class Circle implements Shape {
  constructor(private readonly radius: number) {}
  calculateArea(): number { return Math.PI * this.radius ** 2; }
}

class Rectangle implements Shape {
  constructor(private readonly width: number, private readonly height: number) {}
  calculateArea(): number { return this.width * this.height; }
}

class Triangle implements Shape {
  constructor(private readonly base: number, private readonly height: number) {}
  calculateArea(): number { return (this.base * this.height) / 2; }
}
```

**When to apply:**
- The same switch/if-else appears in multiple methods
- Adding a new type means updating multiple switch statements
- Each branch has substantially different logic

**When NOT to apply:**
- Simple one-off conditionals
- The condition is based on dynamic data, not type identity
- Only one switch exists and it's unlikely to grow

### 7. Introduce Null Object

Eliminates null checks by providing a default no-op implementation.

**Before:**
```typescript
function getDiscount(customer: Customer | null): number {
  if (customer === null) return 0;
  return customer.getDiscount();
}

function getName(customer: Customer | null): string {
  if (customer === null) return "occupant";
  return customer.name;
}
```

**After:**
```typescript
class NullCustomer implements Customer {
  get name(): string { return "occupant"; }
  getDiscount(): number { return 0; }
  isNull(): boolean { return true; }
}

// Now all client code just calls methods — no null checks
function getDiscount(customer: Customer): number {
  return customer.getDiscount();
}
```

**Steps:**
1. Create a subclass/implementation for the null case
2. Override methods to provide safe default behavior
3. Replace all null checks with the Null Object
4. Run tests

### 8. Introduce Assertion

Documents assumptions and catches violations early.

```typescript
function calculateExpense(project: Project): number {
  // This function assumes the project has at least one member
  console.assert(project.members.length > 0, "Project must have members");
  return project.budget / project.members.length;
}
```

Use assertions for conditions that should *never* be false in correct code. Use validation for user input and external data.

## Decision Flowchart

```dot
digraph conditionals {
  rankdir=TB;
  start [label="Complex\nconditional?" shape=diamond];
  q1 [label="Switching on\ntype code?" shape=diamond];
  q2 [label="Deep nesting from\nedge cases?" shape=diamond];
  q3 [label="Complex boolean\nexpression?" shape=diamond];
  q4 [label="Null checks\neverywhere?" shape=diamond];
  q5 [label="Same code in\nall branches?" shape=diamond];

  poly [label="Replace Conditional\nwith Polymorphism" shape=box];
  guard [label="Guard Clauses" shape=box];
  decomp [label="Decompose Conditional\nor Consolidate" shape=box];
  nullobj [label="Introduce\nNull Object" shape=box];
  dup [label="Consolidate Duplicate\nFragments" shape=box];

  start -> q1;
  q1 -> poly [label="yes"];
  q1 -> q2 [label="no"];
  q2 -> guard [label="yes"];
  q2 -> q3 [label="no"];
  q3 -> decomp [label="yes"];
  q3 -> q4 [label="no"];
  q4 -> nullobj [label="yes"];
  q4 -> q5 [label="no"];
  q5 -> dup [label="yes"];
}
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Replacing ALL conditionals with polymorphism | Only replace switches that appear in multiple places or will grow |
| Guard clauses that obscure the main logic | Guard clauses are for edge cases — if all paths are equally important, use if/else |
| Null Object that hides bugs | Null Object should only be used when "do nothing" is valid behavior, not when null indicates an error |
| Over-decomposing simple conditions | `if (x > 0)` doesn't need extraction — only extract when the condition is non-obvious |
| Removing control flags but introducing complex boolean expressions | Sometimes a control flag IS the clearest approach — refactor only when it simplifies |
