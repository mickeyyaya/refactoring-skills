---
name: review-efficiency-patterns
description: Use when you need to allocate limited review time for maximum defect-detection yield — covers risk-based ordering, time-boxing, when to stop, diff-size thresholds, and anti-patterns that waste review bandwidth
---

# Review Efficiency Patterns

## Overview

Review time is finite. A reviewer who spends 90 minutes exhaustively auditing a 20-line config change is less effective than one who spends 20 minutes on that change and uses the remaining 70 minutes on a high-risk security PR. This skill teaches how to maximize defect detection per minute of review by applying risk-based ordering, time-boxing, explicit stopping signals, and session hygiene.

This skill pairs with `review-code-quality-process` (what to check) and `review-accuracy-calibration` (how to calibrate confidence in findings). Use this skill to decide how much time to spend and in what order — use those skills to decide what to look for once you are in the review.

## Risk-Based Review Ordering

Not all code areas carry equal risk. Start with the highest-risk surface before reading anything else. If you only have 10 minutes, you want those 10 minutes on the critical path.

| Change Type | Risk Tier | Review Priority | Why |
|-------------|-----------|----------------|-----|
| Auth, tokens, session management | CRITICAL | Review first, always | Defects are exploitable immediately |
| Security validation, input handling | CRITICAL | Review first, always | Injection and bypass bugs live here |
| Database writes, migrations, deletes | HIGH | Review second | Data loss is irreversible |
| External API calls, payment flows | HIGH | Review second | Failures have real-world consequences |
| Public API contracts, response schemas | HIGH | Review second | Breaking changes cascade to consumers |
| Business logic, calculation, pricing | MEDIUM-HIGH | Review third | Subtle errors go unnoticed until production |
| Error handling, retry logic | MEDIUM | Review third | Silent failures degrade reliability over time |
| Internal service calls, shared utilities | MEDIUM | Review third | Coupling and blast radius risk |
| UI rendering, display logic | LOW-MEDIUM | Review fourth | Visible defects are reported quickly |
| Config changes, feature flags | LOW-MEDIUM | Review fourth | Often high blast radius despite small diff |
| Documentation, comments | LOW | Review last or skip | No runtime impact |
| Generated code, vendor files | SKIP | Do not review | Machine-written; review the generator instead |
| Test files (passing CI) | SKIM | Spot-check only | Confirm coverage intent, skip implementation detail |

Within each tier, order by blast radius: how many users or downstream systems are affected if this code is wrong.

## Time-Boxing Heuristics

Set a time budget before you start reading. Without one, reviews expand to fill available time — and the extra time rarely finds extra defects.

| PR Size (lines changed) | Suggested Budget | Notes |
|-------------------------|-----------------|-------|
| 1–50 lines | 10–20 minutes | Deep review; read every line |
| 51–150 lines | 20–35 minutes | Standard review; cover all risk areas |
| 151–300 lines | 35–55 minutes | Focused review; prioritize by risk tier |
| 301–400 lines | 55–75 minutes | Boundary zone; consider requesting a split |
| 401+ lines | Do not time-box as one unit | Split into risk-area sessions of 30–45 minutes each |

### Diminishing Returns

Review yield is not linear over time. The first 60% of review time typically surfaces 80–90% of the defects. After that, additional time produces increasingly marginal findings — mostly style, naming, and minor edge cases.

Concrete signals that you have hit diminishing returns:

- You have read the same section twice and found nothing new.
- Your last 10 minutes of notes contain only nit-level comments.
- You are making suggestions you know the author will reasonably reject.
- You are reading code that is not in the stated scope of the PR.

When you hit two or more of these signals, the review is done — submit what you have.

## When to Stop Reviewing

Stopping is a skill. Reviewers who do not stop on time either rubber-stamp (stop too early) or gold-plate (never stop). The goal is to stop when marginal review time is better spent elsewhere.

### Hard Stop Signals (stop immediately, regardless of time spent)

- You found a CRITICAL issue (security vulnerability, data loss risk, broken API contract). Stop reading — leave the blocking comment and wait for resolution. Deep-diving the rest of the PR before the critical issue is fixed wastes effort if the author rewrites the affected section.
- CI is failing. The build must be green before detailed review is worthwhile.

### Soft Stop Signals (wrap up within the next 5 minutes)

- No new findings in the last 15 minutes of review.
- All risk-tier CRITICAL and HIGH areas have been covered.
- All happy paths and at least two edge cases per risk area have been traced.
- Remaining unread code is in LOW or SKIP risk tiers (generated, vendor, docs).
- You are experiencing reviewer fatigue (more than 60 continuous minutes reviewing).

### Minimum Viable Review

For very small PRs (<30 lines, single-purpose), the minimum viable review is:

1. Confirm CI is green.
2. Read all changed lines once.
3. Check for any CRITICAL risk-tier surface.
4. Check that a test exists or was updated.

If all four pass, approve. Do not manufacture concerns to justify more time.

## Diff Size and Review Depth

Diff size is a proxy for cognitive load. Larger diffs require explicit depth calibration to avoid surface-level scans that miss defects buried in the middle of a large change.

| Diff Size | Review Depth | Approach |
|-----------|-------------|----------|
| < 50 lines | Deep — read every line | Trace logic, check edge cases, verify tests match behavior |
| 50–200 lines | Standard — cover all risk tiers | Use risk-based ordering; skip generated/test internals |
| 200–400 lines | Focused — prioritize risk tiers | Cover CRITICAL and HIGH fully; spot-check MEDIUM; skip LOW |
| > 400 lines | Segmented — do not review as one unit | Break into risk-area sessions; request a split if possible |

For PRs over 400 lines, attempt to split your review into named segments: "session 1: auth changes", "session 2: DB migrations", "session 3: API surface". Submit partial review comments after each session rather than batching everything at the end. This surfaces blockers earlier and reduces the chance that a large PR sits unreviewed because no single time block is long enough.

## Context Loading Strategy

How you load context before reviewing affects how quickly you find defects. A reviewer who reads the implementation first often gets anchored on the author's framing and misses what is missing.

Recommended load order:

1. **PR description** — understand the stated intent. What problem is being solved? What approach was chosen?
2. **Linked ticket or issue** — understand the acceptance criteria. This is the ground truth for "does this code do what it should".
3. **Tests first** — read the test files before the implementation. Tests reveal intended behavior, edge cases the author considered, and gaps in coverage. A test-first reading is often more efficient at finding missing cases than reading the implementation first.
4. **Implementation** — read the implementation with the tests as a map. Trace the critical paths you identified in the risk table.
5. **Skip generated code** — files tagged as generated, vendored dependencies, lock files, and migration scaffolding. Review the generator configuration or the migration input instead.

For PRs with no PR description or linked ticket, spend 2 minutes writing your own understanding of what the PR does before reviewing. This forces you to surface ambiguity early.

## Oversized PR Handling

A PR over 400 lines of non-generated code is a review antipattern. It hides defects, discourages reviewers, and delays feedback loops. When you encounter one, respond before investing full review effort.

### Response Strategies (in order of preference)

1. **Ask to split** — identify 2–3 natural split points (separate concerns, separate risk tiers) and request the author split the PR before you review. This is the highest-yield option.
2. **Review in declared sessions** — if splitting is not possible (time pressure, merge dependency), declare your sessions explicitly in the PR: "Reviewing auth changes now; will cover migrations in a second pass tomorrow."
3. **Focus on risk areas only** — for truly unsplittable PRs, explicitly limit scope: "I reviewed the security surface and the API contract. I did not review the UI changes or generated files."
4. **Pair review** — for PRs over 600 lines, request a second reviewer and divide the risk tiers between you.

Never silently skim a large PR and approve it. If you did not cover a risk area, say so in your review comment.

## Review Session Management

### Batch vs Interrupt-Driven Reviews

Interrupt-driven reviews (reviewing immediately when a PR is opened) fragment the reviewer's deep work and produce lower-quality feedback. Batch reviews (dedicated review blocks) produce better outcomes.

Recommended approach:

- Schedule two dedicated review blocks per day: one in the morning and one early afternoon.
- Respond to PR notifications in those blocks, not on receipt.
- For urgent reviews (production hotfixes, blocking-PR requests), set a clear urgency threshold with your team — not every PR is urgent.

### Ideal Session Length

- **Single PR session:** 20–60 minutes. Under 20 minutes risks superficiality; over 60 minutes degrades accuracy due to fatigue.
- **Multi-PR session:** Up to 90 minutes total, with a 5-minute break between PRs to reset context.
- **Daily review budget:** 90–120 minutes is sustainable. More than 2 hours of reviews per day degrades the reviewer's ability to do deep work and leads to rubber-stamping.

### Reviewer Fatigue Indicators

- Comment quality drops (shorter, less specific).
- You start approving checks you would normally scrutinize.
- You catch yourself reading the same block multiple times.
- Time-to-first-finding increases compared to your earlier sessions.

When you notice fatigue, stop the session. A fatigued review is worse than a deferred review.

## Anti-Patterns

### Rubber-Stamping

Approving without reading, or reading without thinking. Signs: no comments on any non-trivial PR, review time under 3 minutes for a 200-line PR, comments only on style when there are logic issues present.

Fix: Use the time-box table as a minimum, not a maximum. If you cannot spend the minimum time, decline the review and assign someone else.

### Gold-Plating

Spending review time on low-value improvements when high-severity issues remain unfound. Signs: 10 nit-level style comments on a PR with no tests, requesting variable renames while there is no error handling on an external call.

Fix: Complete risk-tier CRITICAL and HIGH coverage before writing any LOW or NIT comments. If you run out of budget after HIGH tier, skip LOW and NIT entirely.

### Bikeshedding Time Allocation

Spending disproportionate time on the most visible, easiest-to-understand parts of a PR (UI strings, variable names, comment phrasing) because they are cognitively easy, while underweighting the hard parts (data migrations, auth logic).

Fix: Apply the risk tier table at the start of every review session. Track where your minutes are actually going. If you have spent more time on LOW-tier items than HIGH-tier items, rebalance immediately.

### Batch-Rejection Deferred to End

Accumulating all review feedback until the very end of a large PR, then posting a wall of comments at once. This delays the author's feedback loop and often results in the author having to redo work that could have been caught earlier.

Fix: For PRs over 200 lines, post blocking comments on CRITICAL and HIGH issues as you find them — do not wait until you have finished the full review. The author can start addressing blockers while you continue reviewing.

## Priority Decision Flowchart

When you open a PR and need to decide how to allocate the next N minutes, follow this decision sequence:

1. Is CI green? If not — post a "please fix CI first" comment and close the tab. No review budget spent.
2. Count lines changed (excluding generated files). Which size bucket does it fall into?
3. Scan the diff file list for CRITICAL risk-tier files (auth, migrations, input handling). If present, those are session 1.
4. Set your time-box from the heuristics table above. Start a timer.
5. Work through risk tiers in order: CRITICAL, HIGH, MEDIUM-HIGH, MEDIUM. Stop when the timer expires or soft-stop signals appear.
6. Write and post comments. CRITICAL and HIGH comments are posted as blocking requests. MEDIUM and below are suggestions.
7. Confirm you covered at least all CRITICAL surface before approving.

If you run out of time before finishing MEDIUM tier, approve with an explicit note: "Reviewed CRITICAL and HIGH areas fully. Did not review [list of uncovered areas]."

## Reviewer Throughput and Calibration

Tracking personal review patterns over time improves calibration. Useful metrics to observe:

| Metric | Healthy Range | Warning Signal |
|--------|--------------|----------------|
| Average time per 100 lines | 8–15 minutes | Under 5 min (too fast) or over 25 min (too slow) |
| Critical findings per 10 PRs | 1–3 | 0 (may be missing issues) or 8+ (calibration drift) |
| Nit-to-blocker comment ratio | Less than 5:1 | Over 10:1 suggests gold-plating |
| Review turnaround time | Same day | Over 2 business days blocks author progress |
| Reviews declined or split-requested | 10–20% of oversized PRs | 0% may indicate rubber-stamping |

These numbers are not hard SLAs — they are diagnostic signals. A single anomalous week is noise; a pattern over a month is worth examining.

Self-calibration using `review-accuracy-calibration` is recommended at least once per quarter: compare your previous findings against what actually became bugs in production. This identifies both blind spots (things you missed) and false-positive patterns (things you flagged that turned out fine).

## Review Checklist: Efficiency Pre-Flight

Before reading a single line of changed code, run this 2-minute pre-flight:

- [ ] CI status is green (or noted as expected-failing with reason)
- [ ] PR has a description explaining the why, not just the what
- [ ] PR is scoped to one logical change (not feature + refactor + bug fix combined)
- [ ] Diff size is within your available review budget for this session
- [ ] You have identified the 1–3 highest-risk files in the diff
- [ ] Your review timer is set

Skipping the pre-flight and diving straight into code is the single most common source of inefficient reviews. The 2-minute investment always returns more than 2 minutes in focused review time.

## Efficiency Patterns by Team Context

Review efficiency norms vary by team structure and delivery pace. Adjust defaults based on your context:

### High-Velocity Teams (multiple deploys per day)

- Reduce time-box targets by 20% — faster iteration cycles require faster review cycles.
- Raise the PR split threshold to 300 lines — keep PRs small by default.
- Use async batch review windows; avoid blocking authors for more than 4 hours.
- Reserve deep architectural review for design-review meetings, not PR comments.

### Regulated or High-Stakes Systems (finance, healthcare, infrastructure)

- Increase time-box targets by 30–50% for CRITICAL and HIGH tiers.
- Require two reviewers for any CRITICAL risk-tier surface.
- Document review scope explicitly in the PR comment — what was covered and what was not.
- Do not skip LOW-tier checks on security or compliance-adjacent changes.

### Distributed Teams Across Time Zones

- Stagger review windows so authors in each zone receive feedback within their working hours.
- Use async-first review comments — avoid synchronous back-and-forth that forces both parties online at the same time.
- For blocking issues, use a short voice/video call to resolve rather than a long async comment thread.

Efficiency is not purely about minimizing review minutes — it is about maximizing the signal-to-noise ratio of feedback and minimizing the total cycle time from PR open to merge.

## Cross-References

| Skill | Relationship |
|-------|-------------|
| `review-code-quality-process` | Defines what to check within each risk tier and phase |
| `review-accuracy-calibration` | Calibrates confidence in findings; prevents both false positives and missed defects |
| `review-cheat-sheet` | Single-page master reference for all review dimensions; use alongside this skill |
| `review-feedback-quality` | How to write comments that are actionable and appropriately prioritized |
