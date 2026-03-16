---
name: refactor
description: Use when the user asks to refactor code, review code quality, or fix code smells — orchestrates the full refactoring pipeline from detection through fix
---

# /refactor — Full Refactoring Pipeline

## Overview

Single entry point that orchestrates the complete refactoring workflow: detect smells → identify anti-patterns → select technique → apply fix → verify.

## Workflow

Execute these phases in order. Stop early if the user only wants a specific phase.

### Phase 1: Scan & Detect

1. Read the target file(s) the user specified
2. Apply `detect-code-smells` — check for all 23 smells across 5 categories
3. Apply `anti-patterns-catalog` — check for structural design problems
4. Apply `performance-anti-patterns` — check for performance issues
5. Apply `security-patterns-code-review` — quick security scan

Report findings as a table:

```
| # | Location | Smell/Issue | Severity | Category |
```

If no issues found, say so and stop.

### Phase 2: Prioritize

Use `refactoring-decision-matrix` to:
1. Map each detected smell to its primary fix technique
2. Assess difficulty (Easy/Medium/Hard) and risk (Low/Medium/High)
3. Check "When NOT to Refactor" criteria
4. Present prioritized list to user:

```
| # | Issue | Fix Technique | Skill | Difficulty | Risk |
```

Ask user: **"Which issues should I fix? (all / numbers / skip)"**

### Phase 3: Plan

For each selected issue:
1. Identify the specific refactoring technique from the relevant skill:
   - Method-level → `refactor-composing-methods`
   - Class-level → `refactor-moving-features`
   - Data-level → `refactor-organizing-data`
   - Conditional → `refactor-simplifying-conditionals`
   - Interface → `refactor-simplifying-method-calls`
   - Hierarchy → `refactor-generalization`
   - FP patterns → `refactor-functional-patterns`
2. Check if a design pattern would help → `design-patterns-creational-structural`, `design-patterns-behavioral`
3. Check language idioms → `language-specific-idioms`
4. Check type improvements → `type-system-patterns`
5. Present the plan: what changes, why, before/after preview

Ask user: **"Proceed with this plan? (yes / modify / skip)"**

### Phase 4: Execute

1. Apply the refactoring technique step by step
2. Follow immutability principles — never mutate, always create new
3. Keep changes minimal — only fix what was agreed
4. Run tests after each change if test command is available

### Phase 5: Verify

1. Re-scan the changed code for new smells introduced
2. Check that the fix didn't create new problems (e.g., extracting a method but creating Long Parameter List)
3. Apply `review-solid-clean-code` — verify SOLID compliance
4. Apply `review-code-quality-process` — quick quality check on changed code
5. Report: what was fixed, what improved, any remaining items

## Quick Modes

The user can scope the refactoring with arguments:

| Command | Behavior |
|---------|----------|
| `/refactor` | Full pipeline on current file or user-specified files |
| `/refactor scan` | Phase 1 only — detect and report, no changes |
| `/refactor fix <smell>` | Skip to Phase 3-4 for a specific known smell |
| `/refactor security` | Security-focused scan using `security-patterns-code-review` |
| `/refactor performance` | Performance-focused scan using `performance-anti-patterns` |
| `/refactor review` | Full code review using `review-cheat-sheet` as guide |

## Cross-Reference Map

| When you find... | Use skill... |
|------------------|-------------|
| Code smells | `detect-code-smells` |
| Anti-patterns | `anti-patterns-catalog` |
| Which technique to use | `refactoring-decision-matrix` |
| Long/complex methods | `refactor-composing-methods` |
| Misplaced responsibilities | `refactor-moving-features` |
| Data handling issues | `refactor-organizing-data` |
| Complex conditionals | `refactor-simplifying-conditionals` |
| Bad method interfaces | `refactor-simplifying-method-calls` |
| Inheritance problems | `refactor-generalization` |
| FP improvements | `refactor-functional-patterns` |
| Type safety gaps | `type-system-patterns` |
| Design pattern opportunity | `design-patterns-creational-structural`, `design-patterns-behavioral` |
| Architecture violations | `architectural-patterns` |
| Security vulnerabilities | `security-patterns-code-review` |
| Performance issues | `performance-anti-patterns` |
| Database problems | `database-review-patterns` |
| Error handling gaps | `error-handling-patterns` |
| Concurrency bugs | `concurrency-patterns` |
| Test quality issues | `testing-patterns` |
| Observability gaps | `observability-patterns` |
| DI/coupling problems | `dependency-injection-module-patterns` |
| Language anti-idioms | `language-specific-idioms` |
| API contract issues | `review-api-contract` |
| SOLID violations | `review-solid-clean-code` |
| Full code review | `review-cheat-sheet` |
