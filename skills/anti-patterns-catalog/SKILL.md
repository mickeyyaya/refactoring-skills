---
name: anti-patterns-catalog
description: Use when reviewing architecture or design for structural problems, when a codebase is hard to change or extend, when onboarding to a legacy system, or when recurring bugs suggest a deeper design flaw
---

# Software Anti-Patterns Catalog

## Overview

Anti-patterns are recurring solutions that seem reasonable but cause more harm than good. Unlike code smells (surface indicators -- see `detect-code-smells`), anti-patterns describe complete failed solutions at class, module, or system scope. Each entry includes root cause, symptoms, and remediation with cross-references to fix skills.

## When to Use

- Architecture review reveals no clear ownership of responsibilities
- A codebase is routinely described as "nobody dares touch that"
- A single change requires coordinating edits across many files/teams
- Bug fixes in one area consistently break unrelated areas

## Quick Reference

| Category | Anti-Pattern | Severity | Primary Fix Skill |
|----------|-------------|----------|-------------------|
| **Design** | God Object | CRITICAL | `refactor-moving-features` |
| **Design** | Golden Hammer | HIGH | `design-patterns-creational-structural` |
| **Design** | Poltergeist | MEDIUM | `refactor-moving-features` |
| **Design** | Blob | HIGH | `refactor-moving-features` |
| **Development** | Spaghetti Code | HIGH | `refactor-composing-methods` |
| **Development** | Copy-Paste Programming | HIGH | `refactor-composing-methods`, `refactor-generalization` |
| **Development** | Lava Flow | HIGH | `refactor-composing-methods` |
| **Development** | Boat Anchor | MEDIUM | `refactor-moving-features` |
| **Development** | Magic Numbers/Strings | MEDIUM | `refactor-organizing-data` |
| **Development** | Premature Optimization | MEDIUM | `review-solid-clean-code` |
| **Development** | Cargo Cult Programming | MEDIUM | `design-patterns-behavioral` |
| **Architecture** | Big Ball of Mud | CRITICAL | `refactor-moving-features` |
| **Architecture** | Vendor Lock-in | HIGH | `design-patterns-creational-structural` |
| **Architecture** | Singleton Overuse | HIGH | `design-patterns-creational-structural` |

## Design Anti-Patterns

### God Object

- **Symptoms**: 500-1000+ lines, name includes "Manager"/"Controller"/"Processor" with unbounded scope, any feature requires opening this file, 5+ unrelated method groups, untestable without mocking everything
- **Root Cause**: Class started small; features added to the "closest existing class" without enforcing responsibility boundaries
- **Severity**: CRITICAL -- single point of failure, merge conflict hotspot, primary source of Divergent Change
- **Remediation**: Extract Class iteratively -- group related fields/methods into cohesive clusters, promote each to its own class. See `refactor-moving-features`. Related smells: Large Class, Divergent Change in `detect-code-smells`.

### Golden Hammer

- **Symptoms**: Every service built the same way regardless of requirements, complex patterns applied to simple interactions, team defaults to familiar solution without evaluating alternatives
- **Root Cause**: Familiarity reduces perceived risk; teams reach for what they know under deadlines
- **Severity**: HIGH -- wrong-tool choices compound and resist replacement
- **Remediation**: Establish ADR practice. List two alternatives before choosing. Broaden decision space via `design-patterns-creational-structural` and `design-patterns-behavioral`.

### Poltergeist

- **Symptoms**: Class with 1-2 methods that immediately delegate, instantiated and discarded, removable without logic changes
- **Root Cause**: Premature decomposition or class lost purpose during refactoring. Related: Lazy Class smell in `detect-code-smells`.
- **Severity**: MEDIUM -- indirection without value
- **Remediation**: Inline Class from `refactor-moving-features`. If an abstraction layer is warranted, use a proper Facade (`design-patterns-creational-structural`).

### Blob

- **Symptoms**: A `utils`/`helpers`/`common` module with 20+ unrelated exports, imported by everything, public API spans multiple domains, changes cause cascading failures
- **Root Cause**: Shared utility modules grow organically without cohesion checks
- **Severity**: HIGH -- invisible coupling across all importers
- **Remediation**: Audit exports, group by domain, extract domain-specific modules. Use `refactor-moving-features` Move Field/Method at module level.

## Development Anti-Patterns

### Spaghetti Code

- **Symptoms**: Methods 50-200+ lines with 4+ nesting levels, business logic in event/route handlers, callback hell, many implicit state variables
- **Root Cause**: Built incrementally under deadline pressure with no structural plan
- **Severity**: HIGH -- precursor to Big Ball of Mud at scale
- **Remediation**: Extract Method (`refactor-composing-methods`) to break large methods. Separate I/O, domain logic, validation. Replace branching with polymorphism (`refactor-simplifying-conditionals`).

### Copy-Paste Programming

- **Symptoms**: Identical blocks in 3+ locations, bug fixes must be applied in every copy, slight variations in copied code. Related: Duplicate Code smell in `detect-code-smells`.
- **Severity**: HIGH -- every copy is a divergence risk
- **Remediation**: Extract Method (`refactor-composing-methods`), Pull Up Method (`refactor-generalization`). For cross-module duplication, create a shared cohesive utility (not a Blob).

### Lava Flow

- **Symptoms**: "Do not remove" comments, commented-out blocks, unused methods/classes for months+, fear of deletion despite no references
- **Root Cause**: Original authors left without docs; insufficient test coverage for safe deletion
- **Severity**: HIGH -- grows over time, misleads new engineers
- **Remediation**: Build test coverage first, use static analysis to find unreferenced code, delete confidently (version control preserves it). See `refactor-composing-methods`.

### Boat Anchor

- **Symptoms**: Interfaces with no implementations, abstraction layers for use cases that never arrived, unread configuration options. Related: Speculative Generality in `detect-code-smells`.
- **Severity**: MEDIUM -- cognitive overhead without value (YAGNI violation)
- **Remediation**: Remove unused abstractions via Collapse Hierarchy / Inline Class from `refactor-moving-features`.

### Magic Numbers and Strings

- **Symptoms**: Literals like `86400`, `0.15`, `"admin"` in logic, same magic value in multiple places. Related: see `refactor-organizing-data` (Replace Magic Number with Constant).
- **Severity**: MEDIUM -- subtle bugs when values change and one occurrence is missed
- **Remediation**: Replace Magic Number with Symbolic Constant (`refactor-organizing-data`). Group related constants in a dedicated module.

### Premature Optimization

- **Symptoms**: Complex caching for rarely-accessed data, bit manipulation replacing clear arithmetic, "this is faster" comments without profiling data
- **Severity**: MEDIUM -- harder to maintain, often contains subtle bugs
- **Remediation**: Measure first, optimize only proven bottlenecks. Document profiling data that justified it. See `review-solid-clean-code`.

### Cargo Cult Programming

- **Symptoms**: Patterns applied mechanically with no clear benefit (Factory for a single-instantiation class), framework boilerplate preserved without understanding, team cannot explain pattern choice
- **Severity**: MEDIUM -- misapplied patterns create accidental complexity
- **Remediation**: Articulate the problem before applying any pattern. Use `design-patterns-behavioral` and `design-patterns-creational-structural` to understand intent, not just structure.

## Architecture Anti-Patterns

### Big Ball of Mud

- **Symptoms**: No module boundaries, circular dependencies, dependency diagram looks like a web, new features require understanding the entire system
- **Root Cause**: Accumulated Spaghetti Code and God Objects over years without architectural enforcement
- **Severity**: CRITICAL -- end state of other anti-patterns left unaddressed
- **Remediation**: Strangler Fig pattern -- identify one cohesive domain, extract behind a clean interface, route calls through it. Repeat per domain. Do NOT attempt full rewrite. Use `refactor-moving-features` Extract Class / Move Method. Enforce boundaries with package-level dependency rules.

### Vendor Lock-in

- **Symptoms**: Vendor SDK types throughout business logic (not just integration layer), vendor-specific query syntax, deployment scripts coupled to one cloud provider
- **Root Cause**: Fast initial integration favors using vendor SDKs directly; abstraction feels premature with one vendor
- **Severity**: HIGH -- critical during pricing negotiations, outages, or compliance changes
- **Remediation**: Introduce Adapter/Repository layer between vendor SDKs and business logic. Define vendor-agnostic interfaces first. See `design-patterns-creational-structural` (Adapter).

### Singleton Overuse

- **Symptoms**: Many classes access shared state via static getters, tests must reset global state, race conditions from mutable singletons, adding a second instance requires significant refactoring
- **Root Cause**: Easy global access without dependency injection
- **Severity**: HIGH -- global state is the enemy of testability and concurrency safety
- **Remediation**: Replace with Dependency Injection. Pass shared resources via constructors. Reserve Singleton for truly process-wide resources (logger, config). See `design-patterns-creational-structural`.

## Decision Flowchart

```
Is the problem in a single class?
  YES -> Doing too much?  YES -> GOD OBJECT -> refactor-moving-features (Extract Class)
                          NO  -> Doing too little? YES -> POLTERGEIST -> refactor-moving-features (Inline Class)
  NO  -> In a module?
          YES -> Dumping ground? YES -> BLOB -> refactor-moving-features
  NO  -> System-wide?
          No architecture?     -> BIG BALL OF MUD -> incremental strangler fig
          Vendor coupling?     -> VENDOR LOCK-IN -> design-patterns (Adapter)

Daily coding habits?
  Duplicate code?     -> COPY-PASTE -> refactor-composing-methods
  Dead code/fear?     -> LAVA FLOW -> refactor-composing-methods
  Hardcoded literals? -> MAGIC NUMBERS -> refactor-organizing-data
  Tangled control?    -> SPAGHETTI -> refactor-composing-methods
  Speculative code?   -> BOAT ANCHOR -> refactor-moving-features
  Blind patterns?     -> CARGO CULT -> design-patterns-behavioral
  Familiar tool?      -> GOLDEN HAMMER -> design-patterns
  No profiling?       -> PREMATURE OPTIMIZATION -> review-solid-clean-code
  Global state?       -> SINGLETON OVERUSE -> design-patterns
```

## Relationship to Code Smells

Anti-patterns operate at a higher scope than code smells. A God Object typically presents multiple smells simultaneously (Large Class, Divergent Change, Inappropriate Intimacy). Addressing the anti-pattern resolves underlying smells at once. For line/method-level indicators, see `detect-code-smells`.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Treating anti-pattern as root cause when it's a symptom | Trace back to process failure: missing code review, no boundary enforcement |
| Big-bang rewrite to fix Big Ball of Mud | Use incremental extraction; rewrites fail at the same rate |
| Removing God Object by creating many Poltergeists | Each extracted class must have genuine responsibility |
| Fixing Vendor Lock-in with a leaky abstraction | Define interface from consumer's perspective, not vendor's API |
| Labeling every pattern-use as Golden Hammer / Cargo Cult | Patterns are valid when addressing a real, demonstrated problem |
| Conflating Singleton Overuse with legitimate shared resources | Logger/config = valid Singleton; business service via global state = not |
