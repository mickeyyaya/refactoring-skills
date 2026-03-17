---
name: review-automation-patterns
description: Use when configuring or running static analysis in CI pipelines — covers tool selection by language, CI gate configuration, what to automate vs what to review, false positive management, and anti-patterns that undermine automated review value
---

# Review Automation Patterns

## Overview

Machines are better than humans at enforcing rules that have no exceptions: formatting, import ordering, unused variable detection, known vulnerability signatures, and type mismatches. Humans are better than machines at evaluating intent, architecture fitness, naming coherence, test quality, and logic correctness. The goal of review automation is to eliminate the machine-checkable items from human review so that reviewers can spend all their time on the problems that require judgment.

A well-configured automation layer means a reviewer never has to leave a comment about a missing semicolon, an inconsistent indent, or a dependency with a known CVE. Those findings appear as CI failures before the review even begins. What remains for human review is everything that matters: does this code do what the ticket asked, does it fit the architecture, are the edge cases handled, are the tests meaningful.

This skill pairs with `review-efficiency-patterns` (how to allocate review time) and `review-code-quality-process` (what dimensions to check during human review). Use this skill to configure the automated layer that precedes human review. Cross-reference `security-patterns-code-review` for depth on security-specific automated checks.

## Tool Selection by Language

Static analysis tooling is language-specific. Using the wrong tool for a language produces weak signal, high noise, or both. The table below lists the canonical tools for each major language across four categories: linting, type checking, security scanning, and formatting.

| Language | Linter | Type Checker | Security Scanner | Formatter |
|----------|--------|--------------|-----------------|-----------|
| Go | golangci-lint, go vet | go build (compile-time) | gosec | gofmt, goimports |
| Python | ruff (replaces flake8+isort+pyupgrade) | mypy, pyright | bandit, safety | black, ruff format |
| TypeScript | eslint + typescript-eslint | tsc --noEmit | semgrep, npm audit | prettier |
| Rust | clippy | rust-analyzer, rustc | cargo-audit, cargo-deny | rustfmt |
| Java | checkstyle, spotbugs, PMD | javac (compile-time) | snyk, OWASP dependency-check | google-java-format, spotless |
| C++ | clang-tidy, cppcheck | clang (compile-time) | — (use manual review) | clang-format |

Notes on tool selection:

- For Go, prefer `golangci-lint` as the aggregator — it runs `go vet`, `staticcheck`, `errcheck`, and others in a single pass with a unified config file.
- For Python, `ruff` has replaced most of the traditional flake8+isort+pyupgrade stack and is significantly faster. Run `mypy` separately as it is a distinct type-checking phase.
- For TypeScript, `tsc --noEmit` and `eslint` are complementary — `tsc` catches type errors, `eslint` catches code quality and style issues that type checking does not cover.
- For Rust, `clippy` is authoritative and maintained by the Rust project. `cargo-deny` extends `cargo-audit` with license policy enforcement.
- Java's `spotbugs` operates on bytecode and catches null pointer risks, resource leaks, and threading bugs that source-level linters miss.

## Linter-to-Review Dimension Mapping

Each tool category covers specific review dimensions well and leaves others entirely to human reviewers. Understanding this boundary prevents both redundant automation effort and misplaced trust in tooling.

| Review Dimension | Tools That Cover It | What Remains for Human Review |
|-----------------|--------------------|-----------------------------|
| Security | gosec, bandit, semgrep, cargo-audit, snyk, npm audit | Business logic bypasses, authorization flaws, indirect injection via multi-step flows, custom crypto misuse |
| Correctness | tsc, mypy, go vet, rustc, javac, clippy | Logic errors, wrong algorithm, off-by-one in business rules, incorrect state transitions |
| Performance | clippy (some alloc patterns), spotbugs (some threading) | Algorithmic complexity, N+1 queries, unnecessary serialization, cache invalidation logic |
| Style | prettier, black, gofmt, rustfmt, clang-format, eslint | Naming coherence across a feature, comment accuracy, API surface consistency |
| Duplication | PMD (copy-paste detection) | Semantic duplication (same logic expressed differently), structural duplication across services |
| Test quality | coverage thresholds (CI), eslint-plugin-jest | Test intent, meaningful assertions, missing edge cases, test isolation |
| Architecture | — (no tool covers this) | Dependency direction, layer violations, coupling, modularity, fit with existing patterns |
| Dependency health | cargo-deny, npm audit, snyk, safety | Whether a newer version introduces breaking changes, whether a dependency is appropriate for the use case |

The "Architecture" row having no tool coverage is intentional. No static analyzer evaluates whether a change fits the existing system design. This is entirely a human review responsibility and should be the primary focus when automation covers the other dimensions.

## CI Gate Configuration

A three-tier gate model prevents two common failure modes: blocking merges on low-signal warnings, and allowing genuine defects through because every finding is treated as advisory.

### Three-Tier Model

- **error (block)**: Finding must be resolved before merge. CI fails with a non-zero exit code. No exceptions without an explicit inline suppression with a justification comment.
- **warn (warn)**: Finding is surfaced in CI output and in the PR diff annotations but does not block merge. Tracked as technical debt. Reviewed in periodic cleanup cycles.
- **info (advisory)**: Finding is logged but not annotated on the PR. Used for experimental rules being evaluated before promotion to warn or error.

### Assigning Severity

Promote a rule to `error` when:
- The finding category has produced production incidents in the past 12 months
- The false positive rate for the rule is below 5% in your codebase
- The fix is always unambiguous (e.g., unused import, known vulnerable dependency version)

Keep a rule at `warn` when:
- The finding category is valuable but context-dependent (e.g., function complexity thresholds)
- You are introducing a new rule and need to measure false positive rate before enforcing

Use `info` when:
- You are evaluating a new rule against the existing codebase
- You want data without creating reviewer fatigue

### Example Configurations

GitHub Actions with golangci-lint (Go):

```yaml
- name: Lint
  uses: golangci/golangci-lint-action@v4
  with:
    args: --config .golangci.yml
```

`.golangci.yml` gate tiers:

```yaml
linters-settings:
  errcheck:
    check-type-assertions: true
issues:
  # error tier: these exit non-zero and block merge
  exclude-rules:
    - linters: [godot, wsl]
      severity: warning  # demote style-only linters to warn
severity:
  default-severity: error
  rules:
    - linters: [godot, wsl, gocognit]
      severity: warning
```

Python ruff + mypy in CI:

```yaml
- name: Lint (ruff)
  run: ruff check . --output-format=github
- name: Type check (mypy)
  run: mypy src/ --strict --error-summary
```

TypeScript tsc + eslint with threshold:

```yaml
- name: Type check
  run: npx tsc --noEmit
- name: Lint
  run: npx eslint . --max-warnings=0  # warn tier treated as error in CI
```

The `--max-warnings=0` pattern promotes all eslint `warn` rules to gate-level failures in CI while keeping the rule configured as `warn` in `.eslintrc` (which still allows IDE display without red underlines for developers iterating locally).

## What to Automate vs What to Review

Clear delineation prevents both tool sprawl and review scope creep.

### Automate These — Remove From Human Review Scope

- **Formatting**: indentation, line length, trailing whitespace, import ordering. If a formatter exists for the language, no human should ever comment on these. Automate the formatter as a pre-commit hook and a CI check.
- **Unused variables and imports**: all major linters catch these. Never leave a comment about an unused import.
- **Known vulnerable dependency versions**: `cargo-audit`, `npm audit`, `safety`, or `snyk` catch these with zero false positives on known CVEs. This should always be a blocking CI gate.
- **Basic null safety violations**: type checkers with strict null checking (`tsc --strictNullChecks`, `mypy --strict`) catch entire categories of null dereference before code runs.
- **Dead code patterns**: unreachable code, always-true/false conditions that type checkers can evaluate statically.
- **License compliance**: `cargo-deny`, npm license checkers. Encode your license policy in config and let CI enforce it.
- **Secret patterns in diffs**: tools like `gitleaks` or `truffleHog` scan for API key patterns, private key headers, and common secret shapes. Run these on every commit push.

### Reserve These for Human Review

- **Logic correctness**: does the algorithm implement the intended behavior? Does it handle the failure modes described in the ticket?
- **Architecture fit**: does this change respect the existing layer boundaries? Does it introduce new coupling?
- **Naming coherence**: are names consistent across the feature and with the broader codebase vocabulary?
- **Test quality**: are the tests verifying behavior or implementation detail? Do assertions cover the important cases or just the happy path?
- **Error handling intent**: is the error handling appropriate for the severity of the failure? Is user-facing error messaging correct?
- **Security logic**: multi-step authorization flows, indirect injection paths, business-logic-level access control.
- **API surface decisions**: are new endpoints, types, and contracts designed for extensibility? Will this be a breaking change in 6 months?

The test in practice: if a machine can check the rule with a finite set of known patterns and near-zero false positives, automate it. If checking the rule requires understanding business context, system history, or user intent, it is a human review item.

## False Positive Management

Unmanaged false positives destroy trust in the tool chain. When developers learn that a tool generates noise, they start ignoring its output — including the true positives.

### Inline Suppressions

Every suppression must include a justification comment that explains why the finding does not apply:

Go:
```go
//nolint:gosec // G304: path is constructed from validated config values, not user input
file, err := os.Open(configPath)
```

Python:
```python
result = eval(expr)  # noqa: S307 — expr is parsed from validated YAML schema, not user input
```

TypeScript:
```typescript
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- legacy API response type, tracked in #1234
const response: any = await legacyClient.fetch();
```

Suppressions without justification comments should be treated as a code review finding in their own right. A bare `//nolint` or `# noqa` is a warning sign that a developer silenced a tool without understanding it.

### Baseline Files

For projects with existing codebases being brought under linting for the first time, generate a baseline file that records all current violations. CI then only gates on new violations, not the existing backlog.

golangci-lint supports `--new-from-rev` to only report issues introduced since a given commit. mypy supports `--baseline-file`. This prevents the "fix everything before you can use the tool" problem that leads to tools never being adopted.

### Severity Tuning

Measure false positive rates before enforcing a rule. A rule with a 20% false positive rate in your codebase should stay at `warn` or `info` until either the rule is configured more narrowly or the codebase patterns that trigger it are changed.

Establish a periodic review cycle (quarterly) for the warn-tier rules: promote rules where false positives are low, retire rules that have been at warn for over a year with no true positives found.

## Anti-Patterns

### Tool Sprawl

Running 12 different linters that overlap in coverage produces noise, slow CI, and inconsistent configuration maintenance burden. Signs: multiple tools flagging the same issue type, CI lint step takes over 5 minutes, no one knows what each tool is actually checking.

Fix: Consolidate to the canonical aggregator for the language (golangci-lint, ruff) and add specialized tools only when the aggregator genuinely cannot cover a category.

### Ignoring All Warnings

A warn tier that nobody ever looks at is not a warn tier — it is a documentation graveyard. Signs: hundreds of warnings that have accumulated over months, no mechanism to review or promote/retire them.

Fix: Set a warn threshold (e.g., no new warnings allowed even if merge is not blocked) or use the `--max-warnings=N` pattern that makes CI fail if the warning count exceeds a budget.

### Security Theater

Running security scanning tools but treating all findings as advisory and never blocking on them. Signs: `npm audit` shows critical CVEs in dependencies, CI output shows them, nobody fixes them.

Fix: Known critical and high CVEs in direct dependencies must be blocking. Pin the rule: if a dependency has a critical CVE with a fixed version available, merge is blocked until the dependency is updated.

### Auto-Fix Without Review

Automatically committing formatter or fixer output in CI without a developer seeing the diff. Signs: CI pushes commits back to the branch, developers are surprised by code changes they did not write.

Fix: Run formatters and fixers as pre-commit hooks on the developer's machine and as check-only (no write) in CI. Fail CI if the formatter would make changes — require the developer to run the formatter locally before pushing. Never auto-commit.

### Gatekeeping the Wrong Things

Blocking merges on style rules while leaving security findings advisory. The gate tier should reflect real risk, not tooling defaults.

Fix: Audit your current gate configuration and ask for each blocking rule: "would a violation of this rule cause a production incident?" If no, it should be warn or info. For each advisory rule: "has a violation of this rule caused a production incident?" If yes, it should be error.

## Incremental Adoption Strategy

Adding full static analysis to an existing codebase in one step is rarely practical — the noise volume triggers pushback and the tooling gets disabled or ignored. Adopt in phases:

1. **Phase 1 — Formatting only**: Enable the formatter as a pre-commit hook and a CI check. Zero false positives. Zero behavior change. Establishes the habit of running tools before pushing.
2. **Phase 2 — Dependency scanning**: Add `cargo-audit`, `npm audit`, or `safety` as a blocking CI gate for critical and high CVEs. These have near-zero false positive rates and direct security value.
3. **Phase 3 — Type checker with baseline**: Enable the type checker with a baseline file that ignores all pre-existing violations. New code must be type-clean. Work down the baseline over subsequent sprints.
4. **Phase 4 — Linter at warn tier**: Enable the full linter with all findings at warn. Measure false positive rates for 2–4 weeks. Promote low-noise rules to error tier, retire high-noise rules.
5. **Phase 5 — Full gate enforcement**: Promote the consolidated low-false-positive rule set to error tier. Remove the baseline file for the type checker once the backlog is cleared.

This phased approach maintains team trust in the tooling at each stage. Skipping to phase 5 on day one typically results in the tools being disabled by the end of the sprint.

## Pre-Review Automation Checklist

Before a PR reaches human review, the following should have been automatically verified:

- [ ] Formatter has been run and produces no diff (fail fast if not formatted)
- [ ] Linter passes at error tier with no suppressions added in this PR (or suppressions have justification comments)
- [ ] Type checker passes with no new errors
- [ ] Dependency vulnerability scan passes — no new critical or high CVEs in direct dependencies
- [ ] Secret pattern scan passes — no credential patterns in the diff
- [ ] Test suite passes with coverage at or above the configured threshold

If all six pass, the PR is ready for human review. If any fail, the PR is not review-ready and the author must resolve the failures first. This is enforced at the CI gate level, not by reviewer convention.

## Cross-References

| Skill | Relationship |
|-------|-------------|
| `review-efficiency-patterns` | How to allocate human review time after automation clears the mechanical findings |
| `review-code-quality-process` | The review dimensions that remain for human judgment after automated checks pass |
| `security-patterns-code-review` | Depth on security-specific checks — both automated (tool configuration) and manual (what tools cannot catch) |
