---
name: cross-language-review-heuristics
description: Universal code review patterns that apply across all languages. Use this skill when reviewing code regardless of the implementation language — covers naming clarity, complexity thresholds, dependency direction, test quality, error handling, and documentation. Load alongside a language-specific skill (go-review-patterns, python-review-patterns, typescript-review-patterns, rust-review-patterns, java-review-patterns) to get universal + language-calibrated signals in one review pass.
---

# Cross-Language Review Heuristics

## Overview

Some code review signals transcend language syntax. The same structural problems produce the same categories of bugs, maintenance burden, and security risk across all languages.

Universal heuristics are distinct from language-specific idioms. This skill teaches what is structurally problematic in any ecosystem — use it as the first pass, then load the language-specific skill for fine-grained calibration.

## Naming Clarity

Clear naming is the lowest-cost form of documentation.

### Thresholds

Single-character variables acceptable only in tight loops (`i`, `j`, `k`; `n` for count; `x`, `y` for coordinates). Flag at LOW otherwise.

Abbreviations require a project glossary or are limited to universal ones (`id`, `url`, `err`, `ctx`, `msg`). Flag inconsistent or undocumented abbreviations at LOW.

Boolean naming must use an assertion prefix: `is`, `has`, `should`, `can`, `was`, `needs`. Flag ambiguous booleans (`active`, `loading`) at LOW.

Function naming must follow a verb-noun structure. Flag vague or noun-only names (`data()`, `handler()`, `process()`) at LOW. Flag single-word functions with side effects at MEDIUM if the name implies purity.

### Language-Specific Calibration

- Go: exported identifiers must be fully spelled out; unexported identifiers in short functions may use short names if scope is less than 10 lines
- Python: snake_case for variables/functions; PascalCase for classes; SCREAMING_SNAKE_CASE for constants
- TypeScript/JavaScript: camelCase for variables and functions; PascalCase for classes and React components; ALL_CAPS for module-level constants
- Rust: snake_case for functions and variables; PascalCase for types and traits; SCREAMING_SNAKE_CASE for constants
- Java: camelCase for methods and variables; PascalCase for classes; ALL_CAPS for constants in interfaces

## Complexity Thresholds

Cyclomatic complexity correlates linearly with bug count.

### Cyclomatic Complexity

Each `if`, `else if`, `for`, `while`, `case`, `catch`, `&&`, and `||` adds 1.

- Complexity 1-5: No flag.
- Complexity 6-10: No flag, but note if the function is growing.
- Complexity 11-20: Flag at MEDIUM. Decompose.
- Complexity >20: Flag at HIGH. Block if on a critical path or has no tests.

### Nesting Depth

- Depth 1-3: No flag.
- Depth 4: Flag at LOW. Consider extracting the inner block.
- Depth 5+: Flag at MEDIUM. Too many concerns in a single scope.

Early return (guard clauses) is the primary tool for reducing nesting. If you see depth 4+ and no guard clauses, suggest the guard-clause refactor at LOW.

### Function Length

- Under 30 lines: No flag.
- 30-50 lines: No flag, but review for hidden responsibilities.
- 51-80 lines: Flag at LOW if more than one responsibility.
- Over 80 lines: Flag at MEDIUM. Decompose.

Language-specific calibration: Go functions tend toward verbose error handling that inflates line count. A 70-line Go function primarily composed of `if err != nil { return err }` chains is not the same concern as a 70-line Python function with dense logic. Line count is a signal to investigate, not an automatic severity.

## Dependency Direction

### Stable Dependencies Principle

A module should depend on modules that are more stable than itself. Infrastructure code (HTTP handlers, database adapters) changes more often than domain logic. Domain logic should not import infrastructure.

Flag at MEDIUM when: a domain entity or business rule imports from an HTTP, database, or framework package.

### Dependency Inversion

High-level modules should not depend on low-level modules. Both should depend on abstractions. When a high-level service directly instantiates a low-level implementation, it cannot be tested without that implementation.

Flag at MEDIUM when: a function or class instantiates its own dependencies using `new`, constructor calls, or module-level initialization rather than accepting them as parameters.

### Circular Dependency Detection

Circular dependencies prevent incremental compilation, make load order unpredictable, and are a sign of a missing abstraction layer.

Flag at HIGH when: a PR introduces or expands a circular dependency.

### Layer Violations

In layered architectures (presentation → service → domain → data), each layer should only import from the layer directly below it.

Flag at MEDIUM when: a component from the presentation layer imports directly from the data or infrastructure layer.

## Test Quality Signals

### Assertion Density

Each test must contain at least one assertion. Tests with zero assertions always pass and provide no value. Flag at MEDIUM when a test function contains no assertions.

Multiple assertions per test are fine when they together verify a single logical behavior.

### Test Name Describes Behavior

Test names must describe the behavior, not the implementation. Flag at LOW when names are generic verbs without a condition or expected outcome.

Pattern: `<subject>_<scenario>_<expected_result>` or `given <context> when <action> then <result>`.

### No Logic in Tests

Test functions must not contain `if`, `for`, `while`, or `try/catch` (except to verify an exception). Logic in tests means the test itself can have bugs. Flag at MEDIUM.

### Test Isolation

Each test must run in any order, independently of other tests. Flag at HIGH when tests share mutable global state or depend on execution order.

### Coverage as Input, Not Target

Coverage thresholds are inputs, not targets. Flag at MEDIUM when a PR raises coverage by adding tests with no assertions or tests that only verify a function does not throw.

## Error Handling Universals

### Never Swallow Errors

An error that is caught and discarded — with no log, no metric, no re-raise — is undetectable in production.

Flag at HIGH when: a catch block or error branch is empty, or contains only a comment like `// ignore`.

### Propagate Context

When re-raising or wrapping an error, include context that identifies where and why it failed.

Flag at MEDIUM when: an error is re-raised without any added context, and the original error message does not already contain identifying information.

### Fail Fast at Boundaries

Validate inputs at system boundaries: API handlers, queue consumers, file readers, inter-service calls.

Flag at MEDIUM when: a public function or API handler does not validate inputs before using them, and inputs come from external sources.

### Distinguish Recoverable from Fatal

A network timeout on a retry-able operation is recoverable. A missing required configuration value at startup is fatal.

Flag at MEDIUM when: retry logic or error recovery is applied to an error that is clearly not recoverable (missing config, schema validation failure, assertion violation).

## Documentation Completeness

### Public API Documentation

Every exported or public function, method, class, and type must have a documentation comment describing: what it does, what parameters it accepts, what it returns, and any errors it can raise.

Flag at LOW when: a public function has no documentation comment. Flag at MEDIUM when: a public function that is part of an external API has no documentation.

### Architecture Decision Records

For non-obvious design choices — algorithm selection, data structure trade-offs, third-party library choices — the rationale should be recorded: "why this approach and not the obvious alternative?"

Flag at LOW when: a PR introduces a non-obvious technical decision with no explanation.

### Inline Comments for Why, Not What

Comments that restate the code add noise without information. Comments that explain the reason a block exists add value the code alone cannot convey.

Flag at NIT when: a comment restates the code (`// increment i` above `i++`).

Flag at LOW when: a complex or non-obvious algorithm has no explanation of why it works or what invariant it relies on.

## Language-Agnostic Severity Matrix

| Signal Type | Default Severity | Block PR? | Notes |
|---|---|---|---|
| Security gap (injection, auth bypass, secret exposure) | CRITICAL | Yes | Never downgrade below HIGH at C3+ |
| Data loss (destructive write, missing transaction) | CRITICAL | Yes | |
| Logic error (incorrect output, wrong behavior) | HIGH | Yes | |
| Circular dependency introduced | HIGH | Yes | |
| Test shares mutable global state | HIGH | Yes | |
| Error swallowed with no log | HIGH | Yes | |
| Missing input validation at boundary | MEDIUM | Request changes | |
| Cyclomatic complexity 11-20 | MEDIUM | Request changes | |
| Layer violation (presentation → data) | MEDIUM | Request changes | |
| Function length > 80 lines | MEDIUM | Optional | Lower if mostly error handling |
| Missing test assertion | MEDIUM | Request changes | |
| Logic in test | MEDIUM | Request changes | |
| Non-recoverable error in retry loop | MEDIUM | Request changes | |
| Missing context on re-raised error | MEDIUM | Suggest | |
| Nesting depth 4 | LOW | No | Suggest guard clause |
| Undocumented public function | LOW | No | |
| Undocumented architectural decision | LOW | No | |
| Single-char variable outside tight loop | LOW | No | |
| Non-standard abbreviation without glossary | LOW | No | |
| Comment restates code | NIT | No | |
| Missing docstring on internal helper | NIT | No | |

## Review Workflow Using This Skill

Apply heuristics in this order to minimize context-switching:

1. **Naming pass** — Scan all new identifiers. Flag naming violations. Takes 2-3 minutes for a typical PR.
2. **Complexity pass** — Identify functions with 4+ levels of nesting or more than 50 lines. Estimate cyclomatic complexity for the longest functions.
3. **Dependency pass** — Look at new import statements. Trace dependency direction. Check for new circular dependencies.
4. **Test quality pass** — Read new test functions. Check assertion density, test isolation, and whether names describe behavior.
5. **Error handling pass** — Find every error branch. Verify it is not empty and that context is propagated. Check boundary inputs are validated.
6. **Documentation pass** — Verify every new exported or public symbol has a docstring. Check non-obvious decisions for a rationale comment.
7. **Calibration** — Apply review-accuracy-calibration confidence scoring to every finding before posting. Suppress C1 findings.

## Anti-Patterns Reviewers Exhibit

### Universal False Positives

**Line count without responsibility check**: Flagging a 60-line Go function as too long when most lines are `if err != nil { return err }` chains.

**Complexity inflation**: Counting ternary operators or simple boolean expressions as complexity increments. Reserve flags for real branching that generates distinct test cases.

**Naming purism**: Rejecting established codebase conventions (e.g., `ctx` for context, `r` and `w` for HTTP reader/writer). Consistency within a codebase outweighs abstract naming rules.

**Documentation for private helpers**: Requiring docstrings on unexported or private functions called in exactly one place with a self-documenting name.

### Universal Under-Flagging

**Coupling ignored in small PRs**: Treating a two-line change as too small to check dependency direction. Layer violations are easiest to catch early.

**Test isolation overlooked**: Approving tests without checking for shared mutable state because the tests pass in the current execution order. CI parallelism will expose this.

**Error context skipped in "obvious" operations**: Not flagging missing error context on database or network calls. In production, you will have only the error message — make it useful.

## Cross-References

- `go-review-patterns` — Go-specific calibration for error handling, goroutine safety, and interface patterns
- `python-review-patterns` — Python-specific calibration for mutable defaults, duck typing, and exception handling
- `typescript-review-patterns` — TypeScript-specific calibration for type safety, async patterns, and module structure
- `rust-review-patterns` — Rust-specific calibration for ownership, lifetimes, and unsafe blocks
- `java-review-patterns` — Java-specific calibration for checked exceptions, generics, and concurrency primitives
- `review-accuracy-calibration` — Confidence scoring model (C1-C4) and severity calibration; apply after using this skill to filter false positives
