---
name: review-metrics
description: Use when you need to measure and improve review effectiveness — covers defect escape rate, false positive rate, review cycle time, comment resolution rate, reviewer agreement, and coverage metrics with formulas, healthy ranges, and anti-patterns to avoid
---

# Review Metrics

## Overview

What gets measured gets improved. Without metrics, review quality is invisible: teams cannot tell whether reviews are catching defects before production, whether reviewers are calibrated consistently, or whether the review process is slowing delivery unnecessarily. This skill teaches how to collect, calculate, and act on the six core metrics that reveal review effectiveness.

The goal is not to create a surveillance system for reviewers. The goal is to surface systemic problems — rubber-stamping, over-blocking, calibration drift — so the team can correct them. Metrics are diagnostic tools, not performance scores.

This skill pairs with `review-accuracy-calibration` (improving individual reviewer calibration), `review-efficiency-patterns` (optimizing review time allocation), and `review-feedback-quality` (writing comments that are actionable).

## Quick Reference Table

| Metric | Formula | Healthy Range | Warning Signal |
|--------|---------|---------------|----------------|
| Defect Escape Rate | escaped / (found_in_review + escaped) | < 5% | > 10% |
| False Positive Rate | false_positives / total_findings | < 15% | > 25% |
| Review Cycle Time | time from PR opened to approved | < 24h standard PRs | > 48h any PR |
| Comment Resolution Rate | comments_addressed / total_comments | > 90% | < 75% |
| Reviewer Agreement Rate | agreed_findings / total_findings_across_reviewers | > 75% | < 50% |
| Review Coverage | substantive_reviews / total_PRs_merged | > 95% | < 85% |

## Defect Escape Rate

### What It Measures

The fraction of defects that passed through code review undetected and were found later — in QA, staging, or production. This is the primary lagging indicator of review quality.

### Formula

```
defect_escape_rate = escaped_defects / (found_in_review + escaped_defects)
```

Where:
- `escaped_defects` = bugs reported post-merge that originated in reviewed code
- `found_in_review` = defects caught and blocked during review before merge

### Target

Less than 5%. Teams with mature review practices typically see 2–4%.

### How to Track

1. Tag every production bug or post-merge defect with its origin PR using your issue tracker.
2. Separately count review-blocking comments that prevented a defect from merging (categorize as "defect caught").
3. At the end of each sprint or month, tally both counts and apply the formula.

Defects must be attributed to the PR that introduced them, not the PR that fixed them. This requires a brief root-cause step when closing each bug: "Which merge introduced this?"

### Example Calculation

In the last month:
- 12 blocking review comments classified as "defect caught" (found_in_review = 12)
- 3 production bugs traced back to reviewed PRs (escaped_defects = 3)

```
defect_escape_rate = 3 / (12 + 3) = 3 / 15 = 0.20 = 20%
```

This is above the 5% target. Either reviews are missing defects, or the "defect caught" classification is too loose (false positives inflating the denominator). Investigate both possibilities before acting.

### Interpreting Trends

A rising defect escape rate signals one or more of: reviewer fatigue, rubber-stamping, PRs that are too large to review effectively, or coverage gaps (certain areas of the codebase receiving less scrutiny). Use `review-efficiency-patterns` to address the first three; use the Review Coverage metric to address the last.

## False Positive Rate

### What It Measures

The fraction of review findings that turned out to be incorrect — the reviewer flagged something as a defect, but the code was actually fine. High false positive rates erode author trust in reviews, slow cycle time, and cause reviewers to second-guess legitimate findings.

### Formula

```
false_positive_rate = false_positives / total_findings
```

Where:
- `false_positives` = findings the author demonstrated were not actually defects, or that the reviewer withdrew after discussion
- `total_findings` = all blocking or suggested findings posted in reviews

### Target

Less than 15%. A reviewer who is never wrong has likely stopped flagging edge cases. A reviewer whose false positive rate exceeds 25% is eroding author trust.

### How to Track

Two approaches, in order of accuracy:

1. **Resolution tagging** — when a reviewer withdraws a comment or the author demonstrates the finding is incorrect, tag that comment as "false positive" in your review tool. Some tools (GitHub, GitLab) support custom labels or resolution states for this.
2. **Retrospective sampling** — at the end of each sprint, sample 10 PRs. For each finding, determine whether it was valid. Calculate the rate from the sample.

### Calibration

If your false positive rate is above 15%, use `review-accuracy-calibration` to identify the categories where calibration is weakest. Common sources: language-specific idioms mistaken for bugs, framework behavior misunderstood as incorrect, performance concerns flagged without benchmarks.

False positive rate interacts directly with reviewer credibility. Authors who receive many false positives begin to push back on legitimate findings. Track this metric per reviewer, not just at the team level.

## Review Cycle Time

### What It Measures

The elapsed time from when a PR is opened (or marked ready for review) to when it receives a final approval or merge. This is the primary measure of review process latency.

### Formula

```
review_cycle_time = timestamp_approved - timestamp_pr_opened
```

Report as median across all PRs, not mean. A few very slow PRs skew the mean; the median reflects typical experience.

### Target

- Standard PR (< 300 lines, no CRITICAL risk tier): less than 24 hours
- Large or CRITICAL-tier PR: less than 48 hours
- Hotfix PR: less than 2 hours

### Breakdown by Phase

Cycle time decomposes into phases, which helps identify where the bottleneck lives:

| Phase | Definition | Typical Contribution |
|-------|-----------|---------------------|
| Time to first review | PR opened → first reviewer comment | 30–50% of total |
| Author response time | First comment → author response or update | 20–35% of total |
| Re-review time | Author update → follow-up review | 15–25% of total |
| Approval lag | Final comment → approval posted | 5–10% of total |

If cycle time is high, identify which phase dominates. High time-to-first-review means reviewers are not engaging. High author response time means authors are deprioritizing review feedback. High re-review time means reviewers are slow to return to PRs after updates.

### Calculation Example

Track these timestamps from your version control tool's API or webhook events. Most CI/CD platforms expose them as pipeline metadata. For manual tracking, a spreadsheet with columns for PR ID, opened timestamp, approved timestamp, and computed cycle time is sufficient for monthly trend analysis.

## Comment Resolution Rate

### What It Measures

The fraction of review comments that were substantively addressed before the PR was merged. A low rate means review feedback is being ignored or dismissed without acknowledgment.

### Formula

```
comment_resolution_rate = comments_addressed / total_comments
```

### Target

Greater than 90%. Every blocking comment must be resolved. Non-blocking suggestions should be addressed or explicitly acknowledged as deferred.

### Resolved vs Dismissed

These are distinct outcomes and should be tracked separately:

| Resolution Type | Definition | Acceptable? |
|----------------|-----------|-------------|
| Fixed | Author made the change the reviewer requested | Always |
| Acknowledged + deferred | Author explains why it is out of scope, creates follow-up ticket | Acceptable for non-blocking suggestions |
| Discussed and withdrawn | Author demonstrated the finding was incorrect; reviewer withdrew | Acceptable |
| Silently closed | Comment marked resolved without response or visible change | Not acceptable |
| Merged without resolution | PR merged with open blocking comment | Never acceptable |

Silent closes and unresolved merges are the failure modes to watch. Configure your review tool to prevent merging with open blocking comments where possible.

### How to Track

Most review tools (GitHub, GitLab, Gerrit) allow you to filter comments by resolution state. Export resolved vs unresolved counts per PR. Spot-check whether "resolved" comments actually received a substantive response, or were silently dismissed.

## Reviewer Agreement Rate

### What It Measures

When two or more reviewers independently review the same PR, how often do they agree on what is a defect? High agreement means the team has a shared standard of review quality. Low agreement means review outcomes are arbitrary — dependent on which reviewer was assigned rather than the code's actual quality.

### Formula

```
reviewer_agreement_rate = agreed_findings / total_unique_findings_across_reviewers
```

Where:
- `agreed_findings` = findings that two or more reviewers independently identified
- `total_unique_findings_across_reviewers` = all distinct findings (counting each defect once regardless of how many reviewers flagged it)

### Target

Greater than 75% on CRITICAL and HIGH risk-tier findings. Lower agreement on MEDIUM and LOW findings is expected and acceptable — those involve more judgment.

### How to Measure

This metric requires PRs that receive multiple independent reviews. Do not share early reviewers' comments with subsequent reviewers before they have completed their own pass. Then compare findings across reviewers.

If you do not have a practice of multi-reviewer PRs, you can approximate this metric using retrospective analysis: when a post-merge defect is found, would a second reviewer have caught it? This is qualitative but still useful.

### Acting on Low Agreement

Low reviewer agreement on CRITICAL findings indicates one of:
- Reviewers are not applying the same risk-tier framework
- Some reviewers are rubber-stamping
- The codebase has areas where no reviewer has sufficient context

Use `review-accuracy-calibration` to run calibration sessions: have multiple reviewers independently review the same PR, then compare findings in a team discussion. This builds shared standards faster than any written guideline.

## Review Coverage

### What It Measures

The percentage of merged PRs that received a substantive review — not a rubber-stamp. Coverage answers the question: "Is the review process actually running, or is it theater?"

### Formula

```
review_coverage = substantive_reviews / total_PRs_merged
```

### Target

Greater than 95%. Some exclusions are legitimate (automated dependency bumps, generated file updates, hotfixes with post-merge review), but every human-authored change to production code should receive a substantive review.

### Detecting Rubber-Stamps

A rubber-stamp is an approval that provides no defect-detection value. Signals:

- Review time under 2 minutes for a PR over 50 lines
- Zero comments on a PR over 100 lines of logic changes
- Approval posted within seconds of the PR being opened
- The same reviewer approves 100% of a particular author's PRs with zero comments

None of these signals are individually conclusive — a 50-line change from a senior engineer working in a familiar area might legitimately take 3 minutes. Look for patterns across multiple PRs and reviewers.

### How to Track

Flag each approved PR as "substantive" or "rubber-stamp" based on the signals above. Most version control APIs expose per-PR review duration, comment count, and reviewer identity — these can be scripted into a weekly coverage report.

A PR is "substantive" if it meets all of:
1. Review time proportional to diff size (use the heuristics from `review-efficiency-patterns`)
2. At least one comment on PRs over 50 lines (unless the PR is genuinely trivial and CI passes)
3. Reviewer did not approve within 60 seconds of PR creation

## Leading vs Lagging Indicators

These six metrics split into two categories. Leading indicators predict future review quality; lagging indicators confirm past review quality. Use both.

| Metric | Type | Why |
|--------|------|-----|
| Defect Escape Rate | Lagging | Measured after production exposure; reflects past review quality |
| False Positive Rate | Leading | High rates predict future author disengagement and rubber-stamping |
| Review Cycle Time | Leading | Long cycles predict reviewer fatigue and rubber-stamping |
| Comment Resolution Rate | Leading | Low rates predict reviewer distrust and disengagement |
| Reviewer Agreement Rate | Leading | Low rates predict unpredictable review outcomes; calibration gap |
| Review Coverage | Leading | Low coverage predicts future defect escape; the root cause metric |

Leading indicators are more actionable — you can intervene before defects escape. Track both; act on leading indicators before the lagging indicator confirms the problem.

## Anti-Patterns in Metrics

### Goodhart's Law

When a measure becomes a target, it ceases to be a good measure. If you publicly rank reviewers by defect-catch rate, reviewers will start flagging more aggressively to improve their numbers — inflating false positives and eroding author trust. If you track cycle time and penalize slow reviewers, reviewers will approve faster without improving review quality.

Metrics must be treated as diagnostic tools for the team, not performance scores for individuals. Aggregate at the team level. Use individual breakdowns only in private calibration conversations.

### Vanity Metrics

Comment count is not a useful metric. A reviewer who posts 20 style nits provides less value than one who posts 2 blocking defect findings. Track finding classification (blocking, suggestion, nit) rather than raw comment volume.

Approval rate (what fraction of PRs you approve vs request changes) is similarly noisy. A reviewer who approves 90% of PRs may be doing excellent work on a high-quality team, or may be rubber-stamping. Context matters; raw rate does not.

### Punitive Metrics

Never use review metrics to punish individual contributors. Surfacing that a reviewer missed a defect that escaped to production is useful for calibration; surfacing it publicly as a blame exercise causes reviewers to defensively under-flag issues to avoid exposure.

Create a culture where escaped defects are discussed as team learning events, not individual failures. The question is always "How do we prevent this class of defect from escaping again?" not "Whose fault was this?"

### Ignoring Qualitative Signals

Quantitative metrics miss a critical signal: the tone and usefulness of review feedback. A reviewer whose comments are technically correct but condescending or vague produces measurable false positives and resolution rates — but also damages team psychological safety in ways no metric captures.

Complement quantitative metrics with periodic qualitative surveys: "Was this review feedback useful? Did it help you understand why a change was needed?" Use `review-feedback-quality` to address gaps surfaced by qualitative feedback.

## Implementation Guide

### Minimum Viable Metrics Setup

If you are starting from zero, implement in this order:

1. **Week 1–2:** Tag post-merge bugs with their origin PR. This is the data foundation for defect escape rate.
2. **Week 3–4:** Add cycle time tracking. Most version control APIs provide this with minimal scripting.
3. **Month 2:** Add rubber-stamp detection to coverage tracking. Review comment counts and times for merged PRs.
4. **Month 3:** Add false positive tagging. Train reviewers to mark withdrawn findings.
5. **Quarter 2:** Add reviewer agreement tracking by running calibration sessions.

### Review Metrics in the Retrospective

At each team retrospective, spend 5 minutes reviewing the current metric state:

- Which metrics are in healthy range?
- Which metrics are outside warning thresholds?
- What changed since last sprint that might explain movement?
- One concrete action to address the worst metric.

Keep the review brief. Metrics are inputs to decisions, not the meeting's main event.

## Cross-References

| Skill | Relationship |
|-------|-------------|
| `review-accuracy-calibration` | Use to improve individual reviewer calibration when false positive rate or agreement rate is outside range |
| `review-efficiency-patterns` | Use to address high cycle time or rubber-stamping patterns |
| `review-feedback-quality` | Use to improve comment resolution rate and qualitative review satisfaction |
