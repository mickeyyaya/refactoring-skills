---
name: cross-language-review-heuristics
description: Universal code review patterns that apply across all languages. Use this skill when reviewing code regardless of the implementation language — covers naming clarity, complexity thresholds, dependency direction, test quality, error handling, and documentation. Load alongside a language-specific skill (go-review-patterns, python-review-patterns, typescript-review-patterns, rust-review-patterns, java-review-patterns) to get universal + language-calibrated signals in one review pass.
---

# Cross-Language Review Heuristics

## Overview

Some code review signals transcend language syntax and ecosystem conventions. Whether you are reviewing Go, Python, TypeScript, Rust, Java, or C++, the same structural problems produce the same categories of bugs, maintenance burden, and security risk. This skill captures those universal signals so that reviewers working across multiple languages can apply a consistent standard and avoid recalibrating from scratch for each codebase.

Universal heuristics are distinct from language-specific idioms. Language-specific skills (go-review-patterns, python-review-patterns, etc.) teach you what is idiomatic and what is a bug in a given ecosystem. This skill teaches you what is structurally problematic in any ecosystem.

Use this skill as the first pass. Then load the language-specific skill for fine-grained calibration.

## Naming Clarity

Clear naming is the lowest-cost form of documentation. It reduces the time to understand intent and the chance that a future editor misuses a function or variable.

### Thresholds

Single-character variable names are acceptable only in tight loops with a well-understood convention (`i`, `j`, `k` for loop counters; `n` for count; `x`, `y` for coordinates). Outside those contexts, flag at LOW. A name like `d` for a database handle or `r` for a response object is not acceptable — the reader has to track its meaning across the function.

Abbreviations require a project glossary or are limited to universal abbreviations (`id`, `url`, `err`, `ctx`, `msg`). Non-standard abbreviations (`cid` for customer ID, `txn` for transaction) are acceptable only if used consistently across the codebase and documented in a glossary or README. Flag inconsistent or undocumented abbreviations at LOW.

Boolean naming must use an assertion prefix: `is`, `has`, `should`, `can`, `was`, `needs`. A boolean variable named `active`, `loading`, or `enabled` is ambiguous — it does not communicate that the value is a truth condition. Flag at LOW. Examples: `isActive`, `hasPermission`, `shouldRetry`, `canDelete`.

Function naming must follow a verb-noun structure. A function named `data()`, `handler()`, or `process()` does not tell the caller what it does. A function named `fetchUserById()`, `validatePaymentMethod()`, or `scheduleRetry()` is self-documenting. Flag vague or noun-only function names at LOW. Flag single-word functions that have side effects at MEDIUM if the name implies they are pure.

### Language-Specific Calibration

- Go: exported identifiers must be fully spelled out (`WriteFile` not `WriteF`); unexported identifiers in short functions may use short names if the scope is less than 10 lines
- Python: snake_case enforced by convention; class names use PascalCase; constants use SCREAMING_SNAKE_CASE
- TypeScript/JavaScript: camelCase for variables and functions; PascalCase for classes and React components; ALL_CAPS for module-level constants
- Rust: snake_case for functions and variables; PascalCase for types and traits; SCREAMING_SNAKE_CASE for constants
- Java: camelCase for methods and variables; PascalCase for classes; ALL_CAPS for constants in interfaces

## Complexity Thresholds

Complexity is the primary driver of defect density. The research baseline: cyclomatic complexity correlates linearly with bug count. Every branch is a test case that may not be written.

### Cyclomatic Complexity

Cyclomatic complexity counts the number of linearly independent paths through a function. A function with no branches has complexity 1. Each `if`, `else if`, `for`, `while`, `case`, `catch`, `&&`, and `||` adds 1.

- Complexity 1-5: No flag. Well within readable range.
- Complexity 6-10: No flag, but note in review if the function is growing.
- Complexity 11-20: Flag at MEDIUM. The function should be decomposed.
- Complexity >20: Flag at HIGH. Block if the function is on a critical path or has no tests.

### Nesting Depth

Nesting depth measures the maximum indentation level within a function. Deep nesting creates code that is hard to read and hard to test.

- Depth 1-3: No flag.
- Depth 4: Flag at LOW. Consider extracting the inner block into a named function.
- Depth 5+: Flag at MEDIUM. The function has too many concerns in a single scope.

Early return (guard clauses) is the primary tool for reducing nesting. If you see nesting depth 4+ and no guard clauses at the top of the function, suggest the guard-clause refactor at LOW.

### Function Length

- Under 30 lines: No flag.
- 30-50 lines: No flag, but review for hidden responsibilities.
- 51-80 lines: Flag at LOW if the function has more than one responsibility.
- Over 80 lines: Flag at MEDIUM. Decompose into smaller functions, each with a single responsibility.

Language-specific calibration: Go functions tend toward verbose error handling that inflates line count. A 70-line Go function that is primarily `if err != nil { return err }` chains is not the same concern as a 70-line Python function with dense logic. Apply judgment — line count is a signal to investigate, not an automatic severity.

## Dependency Direction

Dependency direction determines how much a change in one module affects other modules. Violating dependency direction rules creates coupling that makes testing and refactoring expensive.

### Stable Dependencies Principle

A module should depend on modules that are more stable than itself. Stability means: fewer reasons to change. Infrastructure code (HTTP handlers, database adapters) changes more often than domain logic. Domain logic should not import infrastructure.

Flag at MEDIUM when: a domain entity or business rule imports from an HTTP, database, or framework package. The signal is an import like `import "net/http"` or `from django.db import models` inside a file that contains core business logic.

### Dependency Inversion

High-level modules should not depend on low-level modules. Both should depend on abstractions (interfaces, protocols, traits). When a high-level service directly instantiates a low-level implementation (database client, HTTP client, filesystem), it cannot be tested without that implementation.

Flag at MEDIUM when: a function or class instantiates its own dependencies using `new`, constructor calls, or module-level initialization rather than accepting them as parameters.

### Circular Dependency Detection

Circular dependencies — module A imports module B and module B imports module A — are a structural defect. They prevent incremental compilation, make load order unpredictable, and are a sign of a missing abstraction layer.

Flag at HIGH when: a PR introduces or expands a circular dependency. Most language toolchains will detect this (Go: `import cycle not allowed`; Python: `ImportError`; TypeScript: warnings from bundlers). Circular dependencies that are not caught at compile time (via dynamic imports, type-only imports) are harder to detect but equally problematic.

### Layer Violations

In layered architectures (presentation → service → domain → data), each layer should only import from the layer directly below it. Skipping a layer (presentation importing from data directly) couples the UI to the database schema.

Flag at MEDIUM when: a component from the presentation layer imports directly from the data or infrastructure layer, bypassing the service or domain layer.

## Test Quality Signals

Test coverage as a percentage is a trailing indicator. These signals predict whether the tests that exist will catch bugs.

### Assertion Density

Each test should contain at least one assertion. Tests with zero assertions always pass and provide no value. Tests with one assertion verify one behavior.

Flag at MEDIUM when: a test function contains no assertions (the function runs but verifies nothing). This is a common pattern when a test is scaffolded but not completed.

Prefer more than one assertion per test only when the assertions together verify a single logical behavior (e.g., verifying both the status code and response body of an API call). Do not write tests that verify many unrelated things — each scenario should be its own test.

### Test Name Describes Behavior

Test names should describe the behavior being tested, not the implementation. A test named `test_create_user` does not tell you what scenario is covered. A test named `test_create_user_returns_409_when_email_already_exists` tells you the input, the condition, and the expected output.

Flag at LOW when: test names are generic verbs without a described condition or expected outcome.

Pattern: `<subject>_<scenario>_<expected_result>` or `given <context> when <action> then <result>`.

### No Logic in Tests

Test functions must not contain `if`, `for`, `while`, or `try/catch` (except when testing that an exception is raised). Logic in tests means the test itself can have bugs, undermining its value as a verification artifact.

Flag at MEDIUM when: a test contains a loop or conditional that determines whether an assertion runs. Extract the assertion into a parameterized test or a table-driven test instead.

### Test Isolation

Each test must be able to run in any order and independently of other tests. A test that passes only when run after another test, or that leaves state (files, database rows, global variables) that affects other tests, is not a test — it is a script.

Flag at HIGH when: tests share mutable global state without setup/teardown, or when tests explicitly depend on execution order.

### Coverage as Input, Not Target

Coverage thresholds (80%, 90%) are inputs into the review conversation, not targets to hit by writing vacuous tests. A codebase with 80% coverage and high assertion density is safer than one with 95% coverage filled with empty test functions.

Flag at MEDIUM when: a PR raises coverage by adding tests that have no assertions, or by adding tests that only verify that a function does not throw. These inflate the metric without improving safety.

## Error Handling Universals

### Never Swallow Errors

An error that is caught and then discarded — with no log, no metric, no re-raise — is undetectable in production. The caller has no way to know the operation failed.

Flag at HIGH when: a catch block or error branch is empty, or when it contains only a comment like `// ignore`. The minimum acceptable response to a caught error is a log statement. For recoverable errors, propagate to the caller. For fatal errors, terminate with a message.

### Propagate Context

When re-raising or wrapping an error, include the context that identifies where and why it failed. An error message like `"error"` is useless. An error message like `"fetchUser: database query failed: connection refused"` tells the operator exactly where to look.

Flag at MEDIUM when: an error is re-raised with `throw e` or `return err` without any added context, and the original error message does not already contain identifying information.

### Fail Fast at Boundaries

Validate inputs at system boundaries: API handlers, queue consumers, file readers, inter-service calls. Invalid input that passes the boundary check propagates deep into the system and produces confusing errors far from the source.

Flag at MEDIUM when: a public function or API handler does not validate its inputs before using them, and the inputs come from external sources (HTTP request, message queue, user input, file parse).

### Distinguish Recoverable from Fatal

Not all errors are equal. A network timeout on a retry-able operation is recoverable. A missing required configuration value at startup is fatal. Treating a fatal error as recoverable (retrying an invalid config) wastes time and masks the root cause.

Flag at MEDIUM when: retry logic or error recovery is applied to an error that is clearly not recoverable (missing config, schema validation failure, assertion violation).

## Documentation Completeness

### Public API Documentation

Every exported or public function, method, class, and type must have a documentation comment that describes: what it does, what parameters it accepts, what it returns, and any errors or exceptions it can raise.

Flag at LOW when: a public function has no documentation comment. Flag at MEDIUM when: a public function that is part of an external API (SDK, library, service contract) has no documentation, because external callers cannot inspect the source.

### Architecture Decision Records

For non-obvious design choices — algorithm selection, data structure trade-offs, third-party library choices, schema design — the rationale should be recorded. The comment does not need to be long, but it should answer: "why this approach and not the obvious alternative?"

Flag at LOW when: a PR introduces a non-obvious technical decision with no explanation in a comment, commit message, or linked document.

### Inline Comments for Why, Not What

Comments that restate the code add noise without adding information. Comments that explain the reason a block exists add value that the code alone cannot convey.

Flag at NIT when: a comment restates the code (`// increment i` above `i++`). Do not flag the absence of these comments — their absence is better than their presence.

Flag at LOW when: a complex or non-obvious algorithm has no explanation of why it works or what invariant it relies on.

## Language-Agnostic Severity Matrix

Use this table to assign the initial severity for any finding from this skill. Then calibrate up or down using the language-specific skill and review-accuracy-calibration confidence scoring.

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

Apply heuristics in this order to minimize context-switching during a review:

1. **Naming pass** — Scan all new identifiers (variables, functions, types). Flag naming violations at their threshold. This takes 2-3 minutes for a typical PR.

2. **Complexity pass** — Identify functions with 4+ levels of nesting or more than 50 lines. Estimate cyclomatic complexity for the longest functions. Flag threshold violations.

3. **Dependency pass** — Look at new import statements. Trace the dependency direction: does any module depend on something less stable than itself? Check for new circular dependencies.

4. **Test quality pass** — Read new test functions. Check assertion density, test isolation, and whether test names describe behavior. Flag empty test bodies immediately.

5. **Error handling pass** — Find every error branch in new code. Verify it is not empty and that context is propagated. Check that boundary inputs are validated.

6. **Documentation pass** — Verify every new exported or public symbol has a docstring. Check non-obvious decisions for a rationale comment.

7. **Calibration** — Apply review-accuracy-calibration confidence scoring to every finding before posting. Suppress findings that are C1 or that require more context than you have.

## Anti-Patterns Reviewers Exhibit

### Universal False Positives

**Line count without responsibility check**: Flagging a 60-line Go function as too long when most lines are `if err != nil { return err }` chains. Count lines of logic, not lines of error handling.

**Complexity inflation**: Counting ternary operators or simple boolean expressions as complexity increments. Reserve cyclomatic complexity flags for real branching that generates distinct test cases.

**Naming purism**: Rejecting established codebase conventions (e.g., `ctx` for context, `r` and `w` for HTTP reader/writer) because they do not match the generic guideline. Consistency within a codebase outweighs abstract naming rules.

**Documentation for private helpers**: Requiring docstrings on unexported or private functions that are called in exactly one place and whose name is self-documenting. Reserve documentation flags for public API surfaces.

### Universal Under-Flagging

**Coupling ignored in small PRs**: Treating a two-line change as too small to check dependency direction. Layer violations are easiest to catch early — a two-line import can introduce a direction reversal that takes weeks to untangle.

**Test isolation overlooked**: Approving tests without checking for shared mutable state because the tests pass in the current execution order. Test order is not guaranteed, and CI parallelism will expose this.

**Error context skipped in "obvious" operations**: Not flagging missing error context on database or network calls because "everyone knows where the error comes from." In production, you will have only the error message — make it useful.

## Cross-References

- `go-review-patterns` — Go-specific calibration for error handling, goroutine safety, and interface patterns; use alongside this skill for Go reviews
- `python-review-patterns` — Python-specific calibration for mutable defaults, duck typing, and exception handling; use alongside this skill for Python reviews
- `typescript-review-patterns` — TypeScript-specific calibration for type safety, async patterns, and module structure; use alongside this skill for TypeScript and JavaScript reviews
- `rust-review-patterns` — Rust-specific calibration for ownership, lifetimes, and unsafe blocks; use alongside this skill for Rust reviews
- `java-review-patterns` — Java-specific calibration for checked exceptions, generics, and concurrency primitives; use alongside this skill for Java reviews
- `review-accuracy-calibration` — Confidence scoring model (C1-C4) and severity calibration; apply after using this skill to filter false positives before posting comments
