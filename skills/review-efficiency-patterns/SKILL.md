---
name: review-efficiency-patterns
description: Use when you need to allocate limited review time for maximum defect-detection yield — covers risk-based ordering, time-boxing, when to stop, diff-size thresholds, and anti-patterns that waste review bandwidth
---

# Review Efficiency Patterns

## Overview

Review time is finite. This skill teaches how to maximize defect detection per minute by applying risk-based ordering, time-boxing, explicit stopping signals, and session hygiene. Pairs with `review-code-quality-process` (what to check) and `review-accuracy-calibration` (how to calibrate findings).

## Risk-Based Review Ordering

Start with the highest-risk surface before reading anything else.

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

Set a time budget before you start reading.

| PR Size (lines changed) | Suggested Budget | Notes |
|-------------------------|-----------------|-------|
| 1–50 lines | 10–20 minutes | Deep review; read every line |
| 51–150 lines | 20–35 minutes | Standard review; cover all risk areas |
| 151–300 lines | 35–55 minutes | Focused review; prioritize by risk tier |
| 301–400 lines | 55–75 minutes | Boundary zone; consider requesting a split |
| 401+ lines | Do not time-box as one unit | Split into risk-area sessions of 30–45 minutes each |

### Diminishing Returns

The first 60% of review time typically surfaces 80–90% of the defects. Signals you have hit diminishing returns:

- You have read the same section twice and found nothing new.
- Your last 10 minutes of notes contain only nit-level comments.
- You are making suggestions you know the author will reasonably reject.
- You are reading code not in the stated scope of the PR.

When you hit two or more of these signals, submit what you have.

## When to Stop Reviewing

### Hard Stop Signals (stop immediately)

- You found a CRITICAL issue. Leave the blocking comment and wait for resolution — deep-diving the rest wastes effort if the author rewrites the affected section.
- CI is failing. The build must be green before detailed review is worthwhile.

### Soft Stop Signals (wrap up within 5 minutes)

- No new findings in the last 15 minutes.
- All risk-tier CRITICAL and HIGH areas have been covered.
- All happy paths and at least two edge cases per risk area have been traced.
- Remaining unread code is in LOW or SKIP risk tiers.
- Reviewer fatigue (more than 60 continuous minutes reviewing).

### Minimum Viable Review

For very small PRs (<30 lines, single-purpose):

1. Confirm CI is green.
2. Read all changed lines once.
3. Check for any CRITICAL risk-tier surface.
4. Check that a test exists or was updated.

If all four pass, approve. Do not manufacture concerns to justify more time.

## Diff Size and Review Depth

| Diff Size | Review Depth | Approach |
|-----------|-------------|----------|
| < 50 lines | Deep — read every line | Trace logic, check edge cases, verify tests match behavior |
| 50–200 lines | Standard — cover all risk tiers | Use risk-based ordering; skip generated/test internals |
| 200–400 lines | Focused — prioritize risk tiers | Cover CRITICAL and HIGH fully; spot-check MEDIUM; skip LOW |
| > 400 lines | Segmented — do not review as one unit | Break into risk-area sessions; request a split if possible |

For PRs over 400 lines, split your review into named segments and submit partial comments after each session. This surfaces blockers earlier.

## Context Loading Strategy

Recommended load order:

1. **PR description** — understand the stated intent
2. **Linked ticket or issue** — acceptance criteria; the ground truth for "does this code do what it should"
3. **Tests first** — reveals intended behavior, edge cases, and gaps in coverage
4. **Implementation** — read with the tests as a map; trace the critical paths
5. **Skip generated code** — files tagged as generated, vendored, lock files, migration scaffolding

For PRs with no description, spend 2 minutes writing your own understanding before reviewing.

## Oversized PR Handling

A PR over 400 lines of non-generated code is a review antipattern. Response strategies (in order of preference):

1. **Ask to split** — identify 2–3 natural split points and request it before you review.
2. **Review in declared sessions** — declare sessions explicitly: "Reviewing auth changes now; will cover migrations in a second pass tomorrow."
3. **Focus on risk areas only** — explicitly limit scope: "I reviewed the security surface and the API contract. I did not review the UI changes or generated files."
4. **Pair review** — for PRs over 600 lines, request a second reviewer and divide the risk tiers.

Never silently skim a large PR and approve it. If you did not cover a risk area, say so.

## Review Session Management

### Batch vs Interrupt-Driven Reviews

Interrupt-driven reviews fragment the reviewer's deep work. Batch reviews produce better outcomes.

- Schedule two dedicated review blocks per day: morning and early afternoon.
- Respond to PR notifications in those blocks, not on receipt.
- Set a clear urgency threshold with your team — not every PR is urgent.

### Ideal Session Length

- **Single PR session:** 20–60 minutes. Under 20 risks superficiality; over 60 degrades accuracy.
- **Multi-PR session:** Up to 90 minutes total, with a 5-minute break between PRs to reset context.
- **Daily review budget:** 90–120 minutes is sustainable. More than 2 hours per day leads to rubber-stamping.

### Reviewer Fatigue Indicators

- Comment quality drops (shorter, less specific).
- You start approving checks you would normally scrutinize.
- You catch yourself reading the same block multiple times.
- Time-to-first-finding increases compared to earlier sessions.

When you notice fatigue, stop the session. A fatigued review is worse than a deferred review.

## Anti-Patterns

### Rubber-Stamping

Approving without reading, or reading without thinking. Signs: no comments on any non-trivial PR, review time under 3 minutes for a 200-line PR.

Fix: Use the time-box table as a minimum. If you cannot spend the minimum time, decline and assign someone else.

### Gold-Plating

Spending review time on low-value improvements when high-severity issues remain unfound. Signs: 10 nit-level comments on a PR with no tests.

Fix: Complete risk-tier CRITICAL and HIGH coverage before writing any LOW or NIT comments.

### Bikeshedding Time Allocation

Spending disproportionate time on the most visible, easiest-to-understand parts while underweighting the hard parts (data migrations, auth logic).

Fix: Apply the risk tier table at the start of every session. If you have spent more time on LOW-tier items than HIGH-tier items, rebalance immediately.

### Batch-Rejection Deferred to End

Accumulating all feedback until the end of a large PR, then posting a wall of comments at once.

Fix: For PRs over 200 lines, post blocking comments on CRITICAL and HIGH issues as you find them — do not wait.

## Priority Decision Flowchart

1. Is CI green? If not — post "please fix CI first" and close the tab.
2. Count lines changed (excluding generated files). Which size bucket?
3. Scan the diff file list for CRITICAL risk-tier files. If present, those are session 1.
4. Set your time-box. Start a timer.
5. Work through risk tiers in order: CRITICAL, HIGH, MEDIUM-HIGH, MEDIUM. Stop when timer expires or soft-stop signals appear.
6. Post comments. CRITICAL and HIGH are blocking requests. MEDIUM and below are suggestions.
7. Confirm you covered at least all CRITICAL surface before approving.

If you run out of time before finishing MEDIUM tier, approve with an explicit note of uncovered areas.

## Reviewer Throughput and Calibration

| Metric | Healthy Range | Warning Signal |
|--------|--------------|----------------|
| Average time per 100 lines | 8–15 minutes | Under 5 min (too fast) or over 25 min (too slow) |
| Critical findings per 10 PRs | 1–3 | 0 (may be missing issues) or 8+ (calibration drift) |
| Nit-to-blocker comment ratio | Less than 5:1 | Over 10:1 suggests gold-plating |
| Review turnaround time | Same day | Over 2 business days blocks author progress |
| Reviews declined or split-requested | 10–20% of oversized PRs | 0% may indicate rubber-stamping |

Self-calibration using `review-accuracy-calibration` is recommended at least once per quarter.

## Review Checklist: Efficiency Pre-Flight

Before reading a single line of changed code:

- [ ] CI status is green (or noted as expected-failing with reason)
- [ ] PR has a description explaining the why, not just the what
- [ ] PR is scoped to one logical change
- [ ] Diff size is within your available review budget
- [ ] You have identified the 1–3 highest-risk files in the diff
- [ ] Your review timer is set

## Efficiency Patterns by Team Context

### High-Velocity Teams (multiple deploys per day)

- Reduce time-box targets by 20%.
- Raise the PR split threshold to 300 lines.
- Use async batch review windows; avoid blocking authors for more than 4 hours.
- Reserve deep architectural review for design-review meetings, not PR comments.

### Regulated or High-Stakes Systems (finance, healthcare, infrastructure)

- Increase time-box targets by 30–50% for CRITICAL and HIGH tiers.
- Require two reviewers for any CRITICAL risk-tier surface.
- Document review scope explicitly — what was covered and what was not.
- Do not skip LOW-tier checks on security or compliance-adjacent changes.

### Distributed Teams Across Time Zones

- Stagger review windows so authors in each zone receive feedback within their working hours.
- Use async-first review comments.
- For blocking issues, use a short voice/video call to resolve rather than a long async thread.

## Cross-References

| Skill | Relationship |
|-------|-------------|
| `review-code-quality-process` | Defines what to check within each risk tier and phase |
| `review-accuracy-calibration` | Calibrates confidence in findings; prevents false positives and missed defects |
| `review-cheat-sheet` | Single-page master reference for all review dimensions |
| `review-feedback-quality` | How to write comments that are actionable and appropriately prioritized |
