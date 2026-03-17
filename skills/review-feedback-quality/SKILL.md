---
name: review-feedback-quality
description: Use when writing review comments to ensure feedback is actionable, constructive, and clearly communicates what must change and why. Covers comment templates by severity, tone and framing, vague vs actionable comparisons, and when to use blocking vs suggesting comments.
---

# Review Feedback Quality — Writing Comments That Get Results

## Overview

The quality of a code review is measured by how many issues get fixed with minimum friction. Vague comments are 3x more likely to be ignored or result in incorrect fixes than comments that state what is wrong, why it matters, and how to fix it.

Use this alongside `review-cheat-sheet` (what to look for) and `review-code-quality-process` (how to run a review end to end).

---

## Comment Templates by Severity

Every comment should answer three questions: **What** is the problem, **Why** it matters, and **How** to fix it. Depth scales with severity.

### CRITICAL — Must Fix Before Merge

```
[CRITICAL] What: <one-line description of the issue>
Why: <the risk or harm — data loss, security breach, crash in production>
Fix: <specific action — code snippet, API to call, pattern to use>
Ref: <link to CVE, docs, or deeper skill if applicable>
```

Example:

```
[CRITICAL] What: User-supplied filename passed directly to os.path.join without sanitization.
Why: Path traversal attack — a filename like "../../etc/passwd" lets an attacker read arbitrary files
on the server.
Fix: Validate that the resolved path starts with the expected base directory:
  base = "/var/uploads"
  safe = os.path.realpath(os.path.join(base, user_filename))
  if not safe.startswith(base):
      raise ValueError("Invalid path")
Ref: skills/security-patterns-code-review
```

### HIGH — Strong Confidence the Change Is Wrong

```
[HIGH] What: <issue description>
Why: <likely defect or maintenance burden this introduces>
Fix: <concrete suggestion>
```

Example:

```
[HIGH] What: getUser() is called inside the loop at line 47.
Why: This fires one DB query per iteration. With 500 users in the list, this is 500 round trips
where a single query with IN (...) would suffice.
Fix: Extract the IDs before the loop, call getUsersByIds(ids), then look up results in a map.
```

### MEDIUM — Likely to Cause a Defect or Maintenance Burden

```
[MEDIUM] What: <issue>
Why: <why this will hurt later>
Fix: <suggested improvement>
```

Example:

```
[MEDIUM] What: The error from fs.readFile() is swallowed — only logged, never returned to the caller.
Why: The caller cannot distinguish success from failure, so any code that depends on this file's
content will silently use stale or empty data.
Fix: Return or re-throw the error so callers can handle it:
  if (err) return callback(err);
```

### LOW — Style, Preference, or Minor Improvement

```
[LOW] <observation and suggested improvement in one or two sentences>
```

Example:

```
[LOW] The function name processData() is too generic to signal intent. Consider renameUserEmailInBulk()
or a similarly descriptive name that matches the actual operation.
```

### NIT — Optional, Reviewer Preference

```
nit: <one-sentence note, clearly optional>
```

Example:

```
nit: Early return here would reduce nesting by one level — personal preference, happy to leave as-is.
```

---

## Actionable vs Vague Comparison

| Category | Vague (Before) | Actionable (After) |
|----------|---------------|-------------------|
| **Naming** | "This name is confusing." | "[LOW] `data` tells the reader nothing about the value's shape or purpose. Rename to `normalizedUserRecords` or `userMap` to match the transformation above." |
| **Performance** | "This might be slow." | "[HIGH] Calling `findById()` inside the loop at line 83 generates one SQL query per item. Replace with a bulk fetch before the loop and a dictionary lookup inside it." |
| **Security** | "Is this safe?" | "[CRITICAL] `query` is built by string concatenation from `req.body.search`. Use a parameterized query or ORM method to prevent SQL injection." |
| **Error handling** | "Handle errors here." | "[MEDIUM] `await fetchConfig()` has no try/catch. If the remote call fails, the unhandled rejection will crash the worker process. Wrap in try/catch and return a fallback config or propagate the error." |
| **Testing** | "Tests are missing." | "[HIGH] There is no test for the case where `userId` is null. This path throws an unhandled TypeError in production — add a test that calls `processUser(null)` and asserts a ValidationError is thrown." |
| **Complexity** | "This is hard to follow." | "[MEDIUM] The conditional at line 112 has 4 nested levels. Extract the inner block to a named function `isEligibleForDiscount(user, cart)` to make the decision logic readable." |
| **Duplication** | "This looks duplicated." | "[LOW] Lines 34–41 are identical to `formatCurrency()` in `src/utils/formatting.ts`. Import and reuse that function instead of duplicating the locale logic." |

---

## Tone and Framing

### Constructive vs Destructive Phrasing

| Destructive | Constructive |
|-------------|--------------|
| "You clearly didn't think about error handling." | "This path is missing error handling — see the [MEDIUM] comment above." |
| "This is wrong." | "This will fail when X — here is a fix." |
| "Why did you do it this way?" | "I am not sure I follow the intent here — could you add a comment explaining the constraint that led to this design?" |
| "This is terrible code." | "[HIGH] This function has grown to 120 lines with four distinct responsibilities. It will be very difficult to test or modify safely — see the split suggestion below." |
| "Obviously you should use a set here." | "[LOW] A Set lookup here is O(1) vs the current O(n) array scan — worth switching if this list can grow." |

### "I" vs "You" Framing

Prefer "I" statements about the code over statements about the author: "I'd find it easier to follow if split" rather than "You should split this." "This will throw if `config` is undefined" rather than "You broke the null check."

### Questions vs Demands

Use questions to surface intent when uncertain. "Is there a reason this bypasses the cache?" is more collaborative than a demand. Reserve declarative statements for clear defects: "[CRITICAL] This deletes all rows when `userId` is null — add a guard clause."

### Acknowledging Good Work

Call out patterns done well — this signals what to repeat, builds trust, and makes critical comments land better. "Nice use of the Result type here." "Good catch adding the index."

---

## What Makes a Comment Actionable

Use this checklist before posting any CRITICAL, HIGH, or MEDIUM comment.

- [ ] **Be Specific** — names the file, line range, variable, or function affected
- [ ] **Explains the impact** — states what will go wrong if the issue is not addressed
- [ ] **Suggests a specific fix** — a code snippet, a function to call, or a reference to a working example. "Refactor this" is not a fix.
- [ ] **Provides relevant context** — links to docs, a related skill, a prior incident, or a standard when the reasoning is non-obvious
- [ ] **Scoped to one finding** — each comment addresses one issue

---

## When to Block vs Suggest

### Block (Request Changes — Do Not Approve)

- **Correctness** — wrong results, throws unexpectedly, or corrupts data
- **Security** — any CRITICAL finding (injection, auth bypass, secret exposure, path traversal)
- **Data integrity** — destructive operations without guards, missing transactions
- **CI is red** — do not approve on a failing build
- **Missing tests for new behavior** when the team has a test-required policy

### Suggest (Leave a Note — Do Not Block)

- **Style or naming** — valid alternatives exist and the current choice is not wrong
- **Performance** — not in a hot path, or the gain is marginal without profiling data
- **Refactoring** — the code works and the improvement is incremental
- **Preference** — both approaches are defensible
- **Nit-level** — explicitly label with "nit:"

### The Blocking Comment Test

Before making a comment blocking, ask: "Would I be comfortable explaining to the team why I held up this merge for this reason?" If no, downgrade to a suggestion.

---

## Anti-Patterns in Review Comments

### Bikeshedding

Spending disproportionate energy on low-stakes cosmetic choices while glossing over structural issues. If you find yourself writing five nit comments and no HIGH or CRITICAL comments on a PR that touches authentication logic, recalibrate.

### Drive-By Comments

Leaving a vague observation ("might want to clean this up") with no actionable follow-through. If something is worth flagging, it is worth explaining.

### Tone-Deaf Criticism

Using the review to vent frustration. A comment like "this is a mess, as usual" damages psychological safety and reduces the likelihood that the author will ask for help in the future.

### Unnecessary Code Dumps

Pasting a complete rewrite of a function. Prefer: identify the problem, show the specific fix for the problematic lines, and let the author integrate it.

### Comment Avalanche on a Risky PR

Leaving 40 comments on a PR that should have been split into three smaller ones. If the PR is too large to review cleanly, say so once at the top and request a split before investing in detailed line comments. See `review-cheat-sheet` Phase 1 for the PR size check.

---

## Cross-References

| Skill | When to Use Alongside This One |
|-------|-------------------------------|
| `review-cheat-sheet` | Master reference for what to look for across all review dimensions |
| `review-code-quality-process` | End-to-end review process — how to structure a full review session |
| `detect-code-smells` | Identifying structural issues to comment on |
| `security-patterns-code-review` | Writing CRITICAL security comments with accurate impact statements |
| `performance-anti-patterns` | Writing HIGH performance comments with specific fix suggestions |
| `error-handling-patterns` | Writing MEDIUM error handling comments with correct remediation |
