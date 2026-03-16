---
name: refactoring-decision-matrix
description: Use when you have identified a code smell and need to select the right refactoring technique, assess risk, and prioritize the work — maps all 23 code smells to specific fix paths, difficulty levels, and risk ratings
---

# Refactoring Decision Matrix

## Overview

This skill is the master navigation guide: "I see THIS smell, I should use THAT technique." It synthesizes the entire refactoring skill library into a single decision aid. Use it after `detect-code-smells` confirms a smell and before diving into a specific refactoring skill.

## How to Use This Matrix

1. Identify the smell category from `detect-code-smells`
2. Find the smell row in the matrix below
3. Select the primary or secondary fix based on context
4. Check the difficulty and risk columns before starting
5. Apply the "When NOT to Refactor" rules to validate now is the right time

---

## Decision Matrix: All 23 Smells

### Bloaters (5 smells)

| Smell | Primary Fix | Primary Skill | Secondary Fix | Secondary Skill | Difficulty | Risk |
|-------|------------|---------------|---------------|-----------------|------------|------|
| Long Method | Extract Method | `refactor-composing-methods` | Replace Method with Method Object | `refactor-composing-methods` | Easy | Low |
| Large Class | Extract Class | `refactor-moving-features` | Extract Subclass | `refactor-generalization` | Medium | Medium |
| Primitive Obsession | Replace Data Value with Object | `refactor-organizing-data` | Replace Type Code with State/Strategy | `refactor-organizing-data` | Medium | Medium |
| Long Parameter List | Introduce Parameter Object | `refactor-simplifying-method-calls` | Preserve Whole Object | `refactor-simplifying-method-calls` | Easy | Low |
| Data Clumps | Extract Class | `refactor-organizing-data` | Introduce Parameter Object | `refactor-simplifying-method-calls` | Easy | Low |

### Object-Orientation Abusers (4 smells)

| Smell | Primary Fix | Primary Skill | Secondary Fix | Secondary Skill | Difficulty | Risk |
|-------|------------|---------------|---------------|-----------------|------------|------|
| Switch Statements | Replace Conditional with Polymorphism | `refactor-simplifying-conditionals` | Replace Type Code with State/Strategy | `refactor-organizing-data` | Medium | Medium |
| Temporary Field | Extract Class (with Null Object) | `refactor-organizing-data` | Introduce Null Object | `refactor-organizing-data` | Medium | Medium |
| Refused Bequest | Replace Inheritance with Delegation | `refactor-generalization` | Extract Superclass (restructure hierarchy) | `refactor-generalization` | Hard | High |
| Alternative Classes with Different Interfaces | Rename Method + Extract Superclass | `refactor-generalization` | Move Method to align interfaces | `refactor-moving-features` | Medium | Medium |

### Change Preventers (3 smells)

| Smell | Primary Fix | Primary Skill | Secondary Fix | Secondary Skill | Difficulty | Risk |
|-------|------------|---------------|---------------|-----------------|------------|------|
| Divergent Change | Extract Class | `refactor-moving-features` | Move Method to separate concern clusters | `refactor-moving-features` | Medium | Medium |
| Shotgun Surgery | Move Method + Move Field (centralize) | `refactor-moving-features` | Inline Class to consolidate | `refactor-moving-features` | Hard | High |
| Parallel Inheritance Hierarchies | Move Method + Move Field to collapse one hierarchy | `refactor-generalization` | Replace Inheritance with Delegation | `refactor-generalization` | Hard | High |

### Dispensables (6 smells)

| Smell | Primary Fix | Primary Skill | Secondary Fix | Secondary Skill | Difficulty | Risk |
|-------|------------|---------------|---------------|-----------------|------------|------|
| Excessive Comments | Extract Method (comment becomes method name) | `refactor-composing-methods` | Rename Method/Variable | `refactor-composing-methods` | Easy | Low |
| Duplicate Code | Extract Method + Pull Up Method | `refactor-composing-methods` | Form Template Method | `refactor-generalization` | Medium | Low |
| Lazy Class | Inline Class | `refactor-moving-features` | Collapse Hierarchy | `refactor-generalization` | Easy | Low |
| Data Class | Move Method (add behavior to data class) | `refactor-organizing-data` | Encapsulate Field | `refactor-organizing-data` | Medium | Low |
| Dead Code | Delete it (verify with tooling) | `refactor-composing-methods` | Remove Parameter (if dead param) | `refactor-simplifying-method-calls` | Easy | Low |
| Speculative Generality | Collapse Hierarchy + Inline Class | `refactor-generalization` | Remove Parameter | `refactor-simplifying-method-calls` | Easy | Low |

### Couplers (5 smells)

| Smell | Primary Fix | Primary Skill | Secondary Fix | Secondary Skill | Difficulty | Risk |
|-------|------------|---------------|---------------|-----------------|------------|------|
| Feature Envy | Move Method (to the class it envies) | `refactor-moving-features` | Extract Method then Move Method | `refactor-moving-features` | Easy | Low |
| Inappropriate Intimacy | Move Method + Move Field | `refactor-moving-features` | Extract Class to encapsulate shared data | `refactor-moving-features` | Medium | High |
| Message Chains | Hide Delegate | `refactor-moving-features` | Extract Method + Move Method | `refactor-moving-features` | Easy | Low |
| Middle Man | Remove Middle Man | `refactor-moving-features` | Inline Method | `refactor-composing-methods` | Easy | Low |
| Incomplete Library Class | Introduce Local Extension (wrapper/subclass) | `refactor-moving-features` | Introduce Foreign Method (single utility) | `refactor-moving-features` | Medium | Low |

---

## Risk Level Definitions

| Risk | Meaning | Precondition |
|------|---------|--------------|
| **Low** | Change is local; easy to verify; one class or method affected | Basic test coverage on the affected unit |
| **Medium** | Multiple callers affected or inheritance involved; regression risk | Integration tests covering the changed path |
| **High** | Public API changes, hierarchy restructuring, or cross-module moves | Full test coverage + migration plan for callers |

## Difficulty Level Definitions

| Difficulty | Meaning |
|-----------|---------|
| **Easy** | Mechanical transformation; IDE can automate most of it; < 30 min |
| **Medium** | Requires design judgment; affects multiple files; 30 min – 2 hours |
| **Hard** | Requires architectural reasoning; may need staged rollout; 2+ hours |

---

## When NOT to Refactor

These conditions override any smell severity. Stop and reassess before touching code when:

1. **Code is about to be deleted or replaced.** Refactoring code that will be gone next sprint wastes time and introduces risk for no lasting benefit.

2. **No tests exist and adding them first is not feasible.** Refactoring without a safety net converts a smell into a potential bug. Add tests first, or defer the refactor.

3. **Ship deadline is within 48 hours.** Feature or fix delivery takes priority. Log the smell as tech debt instead.

4. **The "improvement" adds more complexity than it removes.** If extracting a class requires a new abstraction layer with its own lifecycle, configuration, and dependencies, the cure may be worse than the disease. Measure before acting.

5. **Refactoring changes a public API without a migration plan.** Breaking callers creates downstream bugs. Prepare a deprecation path or versioned interface before restructuring public contracts.

6. **You are in the middle of a different refactoring.** Concurrent refactors multiply the chance of merge conflicts and half-broken states. Finish one, commit, then start the next.

---

## Prioritization Framework

Use this to decide WHEN to do the work, not whether the smell exists.

### CRITICAL — Fix Now (before the next commit)

These smells hide bugs or make the current change impossible to implement safely:

- Shotgun Surgery blocking the feature you are adding
- Inappropriate Intimacy where you cannot isolate a failing test
- Dead Code that masks unreachable error branches
- Any smell with HIGH risk that is on the change path for today's work

**Action:** Refactor before writing new code. Do not ship the feature without fixing this.

### HIGH — Fix During the Feature (same PR)

These smells slow the current feature work but do not block it:

- Long Method in code you must read and modify
- Duplicate Code for logic you are about to add a third copy of
- Switch Statements you must extend with a new branch
- Feature Envy for a method you are adding a parameter to

**Action:** Refactor the specific section you touch. Keep the diff small.

### MEDIUM — Schedule Dedicated Time (tech-debt sprint or next quarter)

These smells slow the team but are not on the immediate change path:

- Large Class not involved in current feature
- Primitive Obsession for domain concepts used in 3+ places
- Divergent Change in a module that changes frequently (measured over the last 10 commits)
- Alternative Classes with Different Interfaces causing confusion in code review

**Action:** Add to the team backlog with a severity label. Assign during planning.

### LOW — Fix Opportunistically (when you are already in the file)

These smells cost comprehension but do not block work:

- Excessive Comments on stable code
- Lazy Class or Middle Man with no active development
- Speculative Generality in rarely-touched code
- Dead Code detected by static analysis in modules with good test coverage

**Action:** Fix if you are already editing the file. Do not create a dedicated PR for these alone.

---

## Smell Frequency Heuristics

These heuristics help you judge severity when the matrix alone is not enough:

- If a smell appears in **1 place**: fix opportunistically
- If a smell appears in **3-5 places**: schedule dedicated time
- If a smell appears in **6+ places**: treat as CRITICAL or HIGH regardless of category

Duplicate Code and Switch Statements are particularly dangerous at scale — each copy or branch that must be updated consistently is a future bug waiting to happen.

---

## Compound Smells (Smells That Travel Together)

Certain smells co-occur reliably. Detecting one should trigger a search for its companions before you start refactoring, because fixing one in isolation often leaves the root cause intact.

| Primary Smell Found | Likely Companions | Root Cause |
|--------------------|-------------------|------------|
| Large Class | Divergent Change, Duplicate Code | Single Responsibility violated — multiple concerns fused over time |
| Long Method | Excessive Comments, Duplicate Code, Long Parameter List | Incremental growth without decomposition |
| Primitive Obsession | Data Clumps, Long Parameter List | Missing domain value object |
| Switch Statements | Duplicate Code, Parallel Inheritance Hierarchies | Type code used instead of polymorphism |
| Feature Envy | Message Chains, Inappropriate Intimacy | Behavior placed in the wrong class |
| Shotgun Surgery | Duplicate Code, Data Clumps | Scattered responsibility without a single owner |
| Refused Bequest | Temporary Field, Alternative Classes with Different Interfaces | Inheritance used for code reuse, not type relationships |

**Compound refactoring order:** Address the root cause smell first. Trying to clean companions without fixing the root cause often leaves the code in a worse state than before — you remove one symptom while the underlying structural problem generates the same smell again.

---

## Refactoring Sequencing Rules

When multiple smells are present in the same module, apply fixes in this order to avoid rework:

1. **Dead Code first** — remove noise before analyzing structure
2. **Duplicate Code second** — consolidate before extracting; extracting duplicated code compounds the problem
3. **Long Method / Large Class third** — decompose the structure once the signal is clear
4. **Coupling smells fourth** (Feature Envy, Inappropriate Intimacy, Message Chains) — move behavior only after class boundaries are stable
5. **Generalization smells last** (Refused Bequest, Parallel Inheritance Hierarchies) — restructure hierarchies only after the individual classes are clean

Committing after each smell fixed keeps the git history reviewable and makes rollback surgical rather than wholesale.

---

## Cross-References

| Topic | Skill |
|-------|-------|
| Detecting all 23 smells with symptoms and triggers | `detect-code-smells` |
| Extract Method, Replace Temp with Query, Method Object | `refactor-composing-methods` |
| Move Method, Extract Class, Hide Delegate, Remove Middle Man | `refactor-moving-features` |
| Replace Conditional with Polymorphism, Decompose Conditional | `refactor-simplifying-conditionals` |
| Introduce Parameter Object, Replace Parameter with Method Call | `refactor-simplifying-method-calls` |
| Replace Data Value with Object, Encapsulate Field, Null Object | `refactor-organizing-data` |
| Extract Superclass, Replace Inheritance with Delegation, Collapse Hierarchy | `refactor-generalization` |
| Pipeline composition, functional patterns for async code | `refactor-functional-patterns` |
| End-to-end examples tracing smell → anti-pattern → refactor → design pattern | `pattern-detection-walkthroughs` |
