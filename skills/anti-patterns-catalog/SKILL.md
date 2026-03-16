---
name: anti-patterns-catalog
description: Use when reviewing architecture or design for structural problems, when a codebase is hard to change or extend, when onboarding to a legacy system, or when recurring bugs suggest a deeper design flaw
---

# Software Anti-Patterns Catalog

## Overview

Anti-patterns are recurring solutions that seem reasonable but cause more harm than good. Unlike code smells (surface-level indicators), anti-patterns describe complete failed solutions with known negative consequences. Each entry below includes the root cause, symptoms, and a concrete remediation path that cross-references targeted fix skills.

This catalog complements `detect-code-smells`, which covers line-level and class-level indicators. Anti-patterns typically operate at a higher scope: class design, module organization, or system architecture.

## When to Use

- Architecture review reveals no clear ownership of responsibilities
- A codebase is routinely described as "nobody dares touch that"
- A single change requires coordinating edits across many files or teams
- New engineers cannot understand the system without extended mentorship
- Bug fixes in one area consistently break unrelated areas
- The team copy-pastes code because "that's how it's always been done"

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

## Category 1: Design Anti-Patterns

Design anti-patterns appear at the class and module boundary level. They signal that responsibilities have been allocated incorrectly.

### God Object

- **Description**: A single class or module that knows about everything and does everything. It accumulates responsibilities over time because it is the "obvious" place to add new features.
- **Symptoms**:
  - Class exceeds 500–1000+ lines
  - Class name includes "Manager", "Controller", "Processor" with unbounded scope
  - Any new feature requires opening this file
  - Class has fields and methods that cluster into 5+ unrelated groups
  - Unit-testing the class is nearly impossible without mocking the entire system
- **Why it Happens**: The class started small and legitimate. Each new feature was added to the "closest existing class." Code review never forced responsibility boundaries.
- **Severity**: CRITICAL — the God Object becomes the single point of failure, the merge conflict hotspot, and the primary source of Divergent Change (see `detect-code-smells`)
- **Remediation**: Apply Extract Class iteratively. Group related fields and methods into cohesive clusters, promote each cluster to its own class, then update the original class to delegate. See `refactor-moving-features` for Extract Class and Move Method techniques. Target: each resulting class should have a single reason to change.

---

### Golden Hammer

- **Description**: Over-applying a familiar tool, framework, or pattern regardless of whether it fits the problem. Named after "if your only tool is a hammer, everything looks like a nail."
- **Symptoms**:
  - Every new service is built the same way regardless of requirements
  - A relational database is used where a key-value store or message queue would suffice
  - A complex design pattern is applied to a simple two-class interaction
  - Team members unfamiliar with alternatives default to the known solution
- **Why it Happens**: Familiarity reduces perceived risk. Teams reach for what they know to meet deadlines.
- **Severity**: HIGH — wrong-tool choices compound over time and resist replacement
- **Remediation**: Establish a lightweight Architecture Decision Record (ADR) practice. Before choosing a solution, list two alternatives and evaluate on fit criteria. Familiarize the team with the pattern catalog in `design-patterns-creational-structural` and `design-patterns-behavioral` so the decision space is wider.

---

### Poltergeist

- **Description**: A class with no real responsibility of its own. It appears briefly, performs some trivial setup or pass-through, then disappears. Its only purpose is calling methods on another object.
- **Symptoms**:
  - Class has one or two methods, each delegating immediately to another class
  - Class is instantiated, used once, and then discarded
  - Removing the class would require no logic changes — only call-site updates
  - Corresponds to the Lazy Class code smell in `detect-code-smells`
- **Why it Happens**: Premature decomposition, or a class that lost its purpose during refactoring but was never removed.
- **Severity**: MEDIUM — adds indirection and comprehension cost without adding value
- **Remediation**: Apply Inline Class from `refactor-moving-features`. Move the poltergeist's trivial logic directly into the caller. If the poltergeist was intended as an abstraction layer, evaluate whether a proper interface or Facade pattern (`design-patterns-creational-structural`) is warranted instead.

---

### Blob

- **Description**: Similar to God Object but at module or package scope. A module accumulates too many unrelated responsibilities, becoming a dumping ground that everything else imports.
- **Symptoms**:
  - A `utils`, `helpers`, or `common` module with 20+ unrelated exports
  - Every other module in the codebase imports from this module
  - The module's public API spans multiple domains (auth, formatting, data access, UI)
  - Changing the module's internals causes cascading test failures across the codebase
- **Why it Happens**: Shared utility modules grow organically. Each engineer adds "one small thing" without considering cohesion.
- **Severity**: HIGH — a Blob module creates invisible coupling; any module that imports it is coupled to all other importers
- **Remediation**: Audit the Blob's exports and group them by domain. Extract domain-specific modules (e.g., `auth-utils`, `date-utils`, `format-utils`). Update import sites incrementally. Use `refactor-moving-features` Move Field/Method techniques at the module level.

---

## Category 2: Development Anti-Patterns

Development anti-patterns emerge from day-to-day coding habits. They reflect shortcuts that trade short-term speed for long-term maintainability.

### Spaghetti Code

- **Description**: Tangled, unstructured control flow with no clear separation of concerns. Code jumps between layers, mixes business logic with I/O, and uses excessive branching.
- **Symptoms**:
  - Methods with 50–200+ lines and 4+ levels of nesting
  - Business logic embedded inside event handlers, route handlers, or database callbacks
  - `goto`-style control flow or deeply nested callbacks (callback hell)
  - Reading the code requires tracking many implicit state variables
- **Why it Happens**: Built incrementally under deadline pressure with no structural plan. Common in early-stage projects where "working" was the only acceptance criterion.
- **Severity**: HIGH — spaghetti code is the most common precursor to Big Ball of Mud at scale
- **Remediation**: Apply Extract Method from `refactor-composing-methods` to break large methods into named, focused functions. Separate concerns by layer: extract I/O, extract domain logic, extract validation. Apply Replace Conditional with Polymorphism from `refactor-simplifying-conditionals` to reduce branching.

---

### Copy-Paste Programming

- **Description**: Duplicating code by copying blocks rather than abstracting shared logic. Each copy diverges slightly over time, making bugs require multi-site fixes.
- **Symptoms**:
  - Identical or near-identical blocks in 3+ locations
  - Bug fixes must be applied in every copy (and some copies get missed)
  - Slight variations in copied code that suggest ad-hoc customization
  - Corresponds directly to the Duplicate Code smell in `detect-code-smells`
- **Why it Happens**: Extraction feels risky or time-consuming. Developers are unaware that a similar implementation already exists.
- **Severity**: HIGH — every copy is a ticking divergence bomb
- **Remediation**: Apply Extract Method from `refactor-composing-methods` for shared logic within a class. Apply Pull Up Method from `refactor-generalization` for logic shared across class hierarchies. For cross-module duplication, create a shared utility function in a cohesive module (not a Blob).

---

### Lava Flow

- **Description**: Dead code that nobody dares remove because its original purpose is unknown and it might be load-bearing. Like cooled lava: hard, immovable, and in the way.
- **Symptoms**:
  - Code with comments like "do not remove — unknown why this is needed"
  - Commented-out blocks preserved "just in case"
  - Unused methods, classes, or files that have existed for months or years
  - Fear of deletion even when IDE analysis shows no references
- **Why it Happens**: Original authors left without documentation. Tests are insufficient to provide confidence that deleting code is safe.
- **Severity**: HIGH — Lava Flow grows over time, clutters the codebase, and misleads new engineers
- **Remediation**: Establish sufficient test coverage first to create a safety net. Use static analysis and IDE tooling to identify unreferenced code. Delete confidently. If unsure, use version control: delete, run tests, revert if tests fail. See `refactor-composing-methods` for Remove Dead Code technique.

---

### Boat Anchor

- **Description**: Code, components, or infrastructure kept in the codebase because they "might be useful later," even though no current feature uses them.
- **Symptoms**:
  - Interfaces with no implementations
  - Abstraction layers built for a second use case that never arrived
  - Configuration options that nothing reads
  - Corresponds to Speculative Generality in `detect-code-smells`
- **Why it Happens**: Engineers anticipate future needs and build ahead (YAGNI violation). The future requirement never materializes.
- **Severity**: MEDIUM — adds cognitive overhead and false signals about the system's capabilities
- **Remediation**: Apply the YAGNI principle strictly. Remove unused abstractions using Collapse Hierarchy and Inline Class from `refactor-moving-features`. When the future requirement eventually arrives, the abstraction can be re-introduced with real requirements driving its design.

---

### Magic Numbers and Strings

- **Description**: Hardcoded literal values scattered throughout code with no explanation of their meaning or origin.
- **Symptoms**:
  - Numeric literals like `86400`, `0.15`, `3` appear directly in logic
  - String literals like `"admin"`, `"USD"`, `"v2"` used as comparison values
  - The same magic value appears in multiple places with no shared constant
  - Changing the value requires a global search to find every occurrence
- **Why it Happens**: Convenient in the short term. Developers avoid the overhead of defining a constant for a value they intend to use once.
- **Severity**: MEDIUM — causes subtle bugs when values need to change and one occurrence is missed
- **Remediation**: Apply Replace Magic Number with Symbolic Constant from `refactor-organizing-data`. Group related constants into a dedicated constants module. Use named configuration values for environment-specific literals.

---

### Premature Optimization

- **Description**: Optimizing code for performance before profiling reveals an actual bottleneck. Sacrifices readability and correctness for speculative speed gains.
- **Symptoms**:
  - Complex caching logic for data that is rarely accessed
  - Bit manipulation or low-level tricks replacing clear arithmetic
  - Inlined logic to "avoid function call overhead" in non-hot paths
  - Comments like "this is faster" without profiling data to support the claim
- **Why it Happens**: Engineers overestimate the cost of clean abstractions and underestimate the compiler/runtime's optimization capabilities.
- **Severity**: MEDIUM — optimized code is harder to maintain and often contains subtle bugs
- **Remediation**: Follow the rule: measure first, optimize only proven bottlenecks. Refer to `review-solid-clean-code` for clean code principles that prioritize clarity. When optimization is genuinely needed, document the profiling data that justified it and keep the optimization localized.

---

### Cargo Cult Programming

- **Description**: Using patterns, libraries, or techniques without understanding why. Copy-pasting boilerplate or applying patterns because "that's how it's done" rather than because they solve a real problem.
- **Symptoms**:
  - Design patterns applied mechanically with no clear benefit (e.g., Factory for a class that is only ever instantiated once)
  - Framework boilerplate preserved verbatim without understanding its purpose
  - Team members cannot explain why a pattern was chosen
  - Pattern usage creates more complexity than the problem it was meant to solve
- **Why it Happens**: Patterns and frameworks are adopted from tutorials or senior engineers without full understanding. Knowledge transfer is incomplete.
- **Severity**: MEDIUM — misapplied patterns create accidental complexity that is harder to remove than the original problem
- **Remediation**: Before applying any pattern, articulate the problem it solves. Use `design-patterns-behavioral` and `design-patterns-creational-structural` to understand intent, not just structure. Conduct brief design reviews when introducing a new pattern to the codebase.

---

## Category 3: Architecture Anti-Patterns

Architecture anti-patterns operate at system scope. They describe structural failures that emerge over months or years and require sustained effort to address.

### Big Ball of Mud

- **Description**: A system with no discernible architecture. Modules are arbitrarily coupled, boundaries do not exist, and changes to one area unpredictably affect others.
- **Symptoms**:
  - No clear module or service boundaries
  - Circular dependencies between packages or modules
  - A diagram of the system's dependencies looks like a web, not a hierarchy
  - New features require understanding the entire system
  - High bus factor: only one engineer understands each area
- **Why it Happens**: Accumulated Spaghetti Code and God Objects over years, combined with no architectural enforcement (linting, code review standards, or package boundaries).
- **Severity**: CRITICAL — the Big Ball of Mud is the end state of many of the other anti-patterns left unaddressed
- **Remediation**: Introduce boundaries incrementally using the Strangler Fig pattern: identify one cohesive domain, extract it behind a clean interface, and route calls through that interface. Repeat per domain. Do not attempt a full rewrite. Use `refactor-moving-features` Extract Class and Move Method to move related logic. Enforce boundaries with package-level dependency rules.

---

### Vendor Lock-in

- **Description**: Over-dependence on a specific vendor's APIs, data formats, or services such that switching vendors would require rewriting large portions of the application.
- **Symptoms**:
  - Vendor-specific SDK types appear throughout business logic (not just in integration layers)
  - Database queries use vendor-specific syntax or features not abstractable via ORM
  - Deployment scripts are coupled to a single cloud provider's CLI
  - Any evaluation of an alternative vendor requires a proof-of-concept rewrite
- **Why it Happens**: Fast initial integration favors using vendor SDKs directly. Abstraction layers feel like premature optimization when there is only one vendor.
- **Severity**: HIGH — lock-in becomes critical during pricing negotiations, vendor outages, or compliance requirements
- **Remediation**: Introduce an Adapter or Repository layer between vendor SDKs and business logic. Vendor-specific code should live only in the integration layer. See `design-patterns-creational-structural` for the Adapter pattern. Define vendor-agnostic interfaces first, then implement the vendor-specific adapter.

---

### Singleton Overuse

- **Description**: Using the Singleton pattern pervasively to provide global access to shared state. Results in hidden coupling and makes testing extremely difficult.
- **Symptoms**:
  - Many classes access shared state via static instance getters
  - Unit tests must reset or mock global state between runs
  - Race conditions appear in concurrent environments because singletons hold mutable state
  - Adding a second instance of a "singleton" (e.g., for multi-tenancy) requires significant refactoring
- **Why it Happens**: Singletons solve a real problem (shared resource management) but are overused because they are easy to access from anywhere without dependency injection.
- **Severity**: HIGH — global state is the primary enemy of testability and concurrency safety
- **Remediation**: Replace Singleton access with Dependency Injection. Pass shared resources explicitly through constructors or function parameters. Reserve Singleton for truly process-wide unique resources (e.g., logger, configuration). See `design-patterns-creational-structural` for the proper Singleton pattern scope and alternatives.

---

## Decision Flowchart

```
Is the problem in a single class?
  YES → Is it doing too much?
          YES → GOD OBJECT → refactor-moving-features (Extract Class)
          NO  → Is it doing too little?
                  YES → POLTERGEIST → refactor-moving-features (Inline Class)
  NO  → Is the problem in a module or package?
          YES → Is it a dumping ground for unrelated utilities?
                  YES → BLOB → refactor-moving-features
          NO  → Is the problem system-wide?
                  YES → Is there no architecture?
                          YES → BIG BALL OF MUD → incremental strangler fig
                        Is there vendor coupling?
                          YES → VENDOR LOCK-IN → design-patterns-creational-structural (Adapter)

Is the problem in daily coding habits?
  Duplicate code?     → COPY-PASTE PROGRAMMING → refactor-composing-methods
  Dead code/fear?     → LAVA FLOW → refactor-composing-methods
  Hardcoded literals? → MAGIC NUMBERS → refactor-organizing-data
  Tangled control?    → SPAGHETTI CODE → refactor-composing-methods
  Speculative code?   → BOAT ANCHOR → refactor-moving-features (Inline/Collapse)
  Blind patterns?     → CARGO CULT → design-patterns-behavioral
  Familiar tool?      → GOLDEN HAMMER → design-patterns-creational-structural
  No profiling?       → PREMATURE OPTIMIZATION → review-solid-clean-code
  Global state?       → SINGLETON OVERUSE → design-patterns-creational-structural
```

## Relationship to Code Smells

Anti-patterns and code smells are related but distinct:

| Level | Tool | Examples |
|-------|------|---------|
| Line / method | `detect-code-smells` | Long Method, Magic Number, Feature Envy |
| Class / module | This catalog (Design) | God Object, Poltergeist, Blob |
| System | This catalog (Architecture) | Big Ball of Mud, Vendor Lock-in |

A God Object typically presents multiple code smells simultaneously: Large Class, Divergent Change, and Inappropriate Intimacy. Addressing the anti-pattern resolves all the underlying smells at once.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Treating an anti-pattern as the root cause when it is a symptom | Trace back to the process failure: missing code review, no architecture boundary enforcement, deadline pressure |
| Attempting a big-bang rewrite to fix Big Ball of Mud | Use incremental extraction; rewrites fail at the same rate as the original system |
| Removing a God Object by creating many Poltergeists | Ensure each extracted class has genuine responsibility, not just delegation |
| Fixing Vendor Lock-in by adding a leaky abstraction | Define the interface from the consumer's perspective, not the vendor's API surface |
| Labeling every pattern-use as Golden Hammer or Cargo Cult | Patterns are valid when they address a real, demonstrated problem — evaluate intent, not just presence |
| Conflating Singleton Overuse with legitimate shared resources | A logger or config object is a valid Singleton; a business-logic service accessed via global state is not |
