---
name: review-automation-patterns
description: Use when configuring or running static analysis in CI pipelines — covers tool selection by language, CI gate configuration, what to automate vs what to review, false positive management, and anti-patterns that undermine automated review value
---

# Review Automation Patterns

## Overview

Machines enforce rules with no exceptions (formatting, unused variables, known CVEs, type mismatches). Humans evaluate intent, architecture fitness, naming coherence, test quality, and logic correctness. The goal of review automation is to eliminate machine-checkable items from human review.

Pairs with `review-efficiency-patterns` and `review-code-quality-process`. Cross-reference `security-patterns-code-review` for security-specific automated checks.

## Tool Selection by Language

| Language | Linter | Type Checker | Security Scanner | Formatter |
|----------|--------|--------------|-----------------|-----------|
| Go | golangci-lint, go vet | go build (compile-time) | gosec | gofmt, goimports |
| Python | ruff (replaces flake8+isort+pyupgrade) | mypy, pyright | bandit, safety | black, ruff format |
| TypeScript | eslint + typescript-eslint | tsc --noEmit | semgrep, npm audit | prettier |
| Rust | clippy | rust-analyzer, rustc | cargo-audit, cargo-deny | rustfmt |
| Java | checkstyle, spotbugs, PMD | javac (compile-time) | snyk, OWASP dependency-check | google-java-format, spotless |
| C++ | clang-tidy, cppcheck | clang (compile-time) | — (use manual review) | clang-format |

Notes:
- For Go, prefer `golangci-lint` as the aggregator — runs `go vet`, `staticcheck`, `errcheck`, and others in a single pass.
- For Python, `ruff` has replaced the traditional flake8+isort+pyupgrade stack and is significantly faster. Run `mypy` separately.
- For TypeScript, `tsc --noEmit` and `eslint` are complementary — `tsc` catches type errors, `eslint` catches code quality issues.
- For Rust, `clippy` is authoritative and maintained by the Rust project. `cargo-deny` extends `cargo-audit` with license policy enforcement.
- Java's `spotbugs` operates on bytecode and catches null pointer risks, resource leaks, and threading bugs that source-level linters miss.

## Linter-to-Review Dimension Mapping

| Review Dimension | Tools That Cover It | What Remains for Human Review |
|-----------------|--------------------|-----------------------------|
| Security | gosec, bandit, semgrep, cargo-audit, snyk, npm audit | Business logic bypasses, authorization flaws, indirect injection, custom crypto misuse |
| Correctness | tsc, mypy, go vet, rustc, javac, clippy | Logic errors, wrong algorithm, off-by-one in business rules, incorrect state transitions |
| Performance | clippy (some alloc patterns), spotbugs (some threading) | Algorithmic complexity, N+1 queries, unnecessary serialization, cache invalidation |
| Style | prettier, black, gofmt, rustfmt, clang-format, eslint | Naming coherence across a feature, comment accuracy, API surface consistency |
| Duplication | PMD (copy-paste detection) | Semantic duplication, structural duplication across services |
| Test quality | coverage thresholds (CI), eslint-plugin-jest | Test intent, meaningful assertions, missing edge cases, test isolation |
| Architecture | — (no tool covers this) | Dependency direction, layer violations, coupling, modularity, fit with existing patterns |
| Dependency health | cargo-deny, npm audit, snyk, safety | Whether a newer version introduces breaking changes |

The "Architecture" row having no tool coverage is intentional. No static analyzer evaluates whether a change fits the existing system design — this is entirely a human review responsibility.

## CI Gate Configuration

A three-tier gate model prevents two failure modes: blocking merges on low-signal warnings, and allowing genuine defects through because every finding is advisory.

### Three-Tier Model

- **error (block)**: Must be resolved before merge. CI fails with non-zero exit code. No exceptions without an explicit inline suppression with a justification comment.
- **warn (warn)**: Surfaced in CI output and PR diff annotations but does not block merge. Tracked as technical debt.
- **info (advisory)**: Logged but not annotated on the PR. Used for experimental rules being evaluated before promotion.

### Assigning Severity

Promote to `error`: finding has caused production incidents in 12 months, false positive rate below 5%, fix is always unambiguous.

Keep at `warn`: valuable but context-dependent findings, or new rules being measured.

Use `info`: evaluating a rule without creating reviewer fatigue.

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

The `--max-warnings=0` pattern promotes all eslint `warn` rules to gate-level failures in CI while keeping them as `warn` in `.eslintrc` for IDE display.

## What to Automate vs What to Review

### Automate These — Remove From Human Review Scope

- **Formatting**: If a formatter exists for the language, no human should ever comment on these.
- **Unused variables and imports**: All major linters catch these.
- **Known vulnerable dependency versions**: `cargo-audit`, `npm audit`, `safety`, or `snyk` — always a blocking CI gate.
- **Basic null safety violations**: Type checkers with strict null checking catch entire categories before code runs.
- **Dead code patterns**: Unreachable code, always-true/false conditions.
- **License compliance**: `cargo-deny`, npm license checkers. Encode policy in config.
- **Secret patterns in diffs**: Tools like `gitleaks` or `truffleHog` scan on every commit push.

### Reserve These for Human Review

- **Logic correctness**: Does the algorithm implement the intended behavior?
- **Architecture fit**: Does this change respect existing layer boundaries?
- **Naming coherence**: Are names consistent across the feature and codebase vocabulary?
- **Test quality**: Are tests verifying behavior or implementation detail?
- **Error handling intent**: Is the error handling appropriate for the severity of the failure?
- **Security logic**: Multi-step authorization flows, indirect injection paths, business-logic-level access control.
- **API surface decisions**: Designed for extensibility? Breaking change in 6 months?

The test in practice: if a machine can check the rule with a finite set of known patterns and near-zero false positives, automate it. If checking requires understanding business context, system history, or user intent, it is a human review item.

## False Positive Management

Unmanaged false positives destroy trust — developers start ignoring all tool output.

### Inline Suppressions

Every suppression must include a justification comment:

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

A bare `//nolint` or `# noqa` without justification is itself a code review finding.

### Baseline Files

Generate a baseline file recording all current violations. CI then only gates on new violations. `golangci-lint` supports `--new-from-rev`; `mypy` supports `--baseline-file`.

### Severity Tuning

Measure false positive rates before enforcing a rule. A 20% false positive rate means stay at `warn` or `info` until configured more narrowly.

Establish a periodic review cycle (quarterly): promote rules where false positives are low, retire rules at warn for over a year with no true positives.

## Anti-Patterns

### Tool Sprawl

Running many overlapping linters. Fix: Consolidate to the canonical aggregator (golangci-lint, ruff) and add specialized tools only when the aggregator cannot cover the category.

### Ignoring All Warnings

A warn tier nobody looks at is a documentation graveyard. Fix: Set a warn threshold or use `--max-warnings=N` to fail CI if the count exceeds a budget.

### Security Theater

Running security scanning tools but treating all findings as advisory. Fix: Known critical and high CVEs in direct dependencies must be blocking.

### Auto-Fix Without Review

Automatically committing formatter output in CI. Fix: Run formatters as pre-commit hooks on the developer's machine and check-only in CI. Never auto-commit.

### Gatekeeping the Wrong Things

Blocking merges on style rules while leaving security findings advisory. Fix: For each blocking rule — "would a violation cause a production incident?" If no, demote. For each advisory rule — "has a violation caused an incident?" If yes, promote to error.

## Incremental Adoption Strategy

1. **Phase 1 — Formatting only**: Enable formatter as pre-commit hook and CI check. Zero false positives.
2. **Phase 2 — Dependency scanning**: Add `cargo-audit`, `npm audit`, or `safety` as a blocking CI gate for critical and high CVEs.
3. **Phase 3 — Type checker with baseline**: Enable type checker with a baseline file. New code must be type-clean.
4. **Phase 4 — Linter at warn tier**: Enable full linter at warn. Measure false positive rates for 2–4 weeks. Promote low-noise rules to error.
5. **Phase 5 — Full gate enforcement**: Promote consolidated rule set to error tier. Remove the baseline file once the backlog is cleared.

Skipping to phase 5 on day one typically results in the tools being disabled by the end of the sprint.

## Pre-Review Automation Checklist

Before a PR reaches human review:

- [ ] Formatter has been run and produces no diff
- [ ] Linter passes at error tier (suppressions have justification comments)
- [ ] Type checker passes with no new errors
- [ ] Dependency vulnerability scan passes — no new critical or high CVEs
- [ ] Secret pattern scan passes — no credential patterns in the diff
- [ ] Test suite passes with coverage at or above the configured threshold

If all six pass, the PR is ready for human review.

## Cross-References

| Skill | Relationship |
|-------|-------------|
| `review-efficiency-patterns` | How to allocate human review time after automation clears the mechanical findings |
| `review-code-quality-process` | The review dimensions that remain for human judgment after automated checks pass |
| `security-patterns-code-review` | Depth on security-specific checks — both automated and manual |
