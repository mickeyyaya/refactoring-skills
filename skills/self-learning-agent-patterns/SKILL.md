---
name: self-learning-agent-patterns
description: Use when designing AI agents that improve from experience — covers learning signal detection, instinct extraction, confidence scoring, feedback loop architecture, pattern graduation pipelines, memory-backed learning, safety constraints, and self-learning anti-patterns with examples in TypeScript and Python
---

# Self-Learning Agent Patterns

## Overview

Reactive agents respond to each task independently, carrying no memory of what worked or failed before. Adaptive agents extract structured knowledge from their own experience and apply it to future tasks. Self-learning patterns define the pipeline by which raw observations become instincts, instincts become rules, and rules become skills — moving an agent from static to compound improvement over time.

**When to use:** Designing agents that operate repeatedly on similar tasks and should improve with use; building multi-agent pipelines with feedback loops; reviewing agent memory architectures for learning capability; any system where observed success and failure should influence future agent behavior.

## Quick Reference

| Pattern | Signal | Extraction Method | Graduation Criteria | Application |
|---------|--------|-------------------|---------------------|-------------|
| Repeated Correction Capture | User corrects same error 2+ times | Log correction event → diff original vs corrected | 3+ occurrences, confidence > 0.7 | Promote to instinct |
| Success Pattern Mining | Task completes without correction | Extract strategy fingerprint from successful run | 5+ successful uses across sessions | Promote to instinct |
| Failure Taxonomy | Task fails or is retried | Classify error type, extract trigger conditions | 2+ failures with same root cause | Promote to negative rule |
| Preference Accumulation | User accepts output unchanged | Log format/style choices accepted without edit | Consistent across 10+ sessions | Promote to style rule |
| Temporal Outcome Tracking | Downstream metric improves/degrades | Attribute metric change to prior agent decision | Statistically significant correlation | Adjust strategy weight |

## Learning Signal Detection

A learning signal is any observable event that carries information about agent performance. Signals must be detected, classified, and recorded before extraction can occur.

**Explicit signals — user-initiated:**

- **Direct corrections** — user edits agent output, indicating the original was wrong or suboptimal
- **Rejection events** — user discards output entirely and requests a retry with different instructions
- **Positive confirmation** — user accepts output and applies it without modification
- **Verbal feedback** — user provides qualitative feedback ("too verbose", "good format", "wrong tone")

**Implicit signals — inferred from behavior:**

- **Task success/failure** — did the downstream task complete? Did the generated code compile and pass tests?
- **Retry patterns** — if the same task type triggers retries consistently, the strategy is flawed
- **Output consumption rate** — if outputs are consistently truncated or expanded by users, length calibration is off
- **Time-to-accept** — long review times suggest output quality requires significant manual work

**Temporal signals — long-horizon:**

- **Outcome correlation** — was a downstream goal achieved N steps after the agent's contribution?
- **Regression detection** — did a previously passing eval start failing after a strategy change?
- **Drift detection** — has the distribution of task types shifted such that old instincts no longer apply?

```typescript
type SignalType = "correction" | "rejection" | "acceptance" | "failure" | "retry" | "feedback";

interface LearningSignal {
  id: string;
  ts: string;
  type: SignalType;
  taskType: string;
  sessionId: string;
  agentStrategy: string;
  originalOutput: string;
  correctedOutput?: string;
  feedbackText?: string;
  metadata: Record<string, unknown>;
}

function detectSignal(
  originalOutput: string,
  userAction: "accept" | "edit" | "reject" | "retry",
  userEdit?: string,
  taskType?: string
): LearningSignal {
  const typeMap: Record<typeof userAction, SignalType> = {
    accept: "acceptance",
    edit: "correction",
    reject: "rejection",
    retry: "retry",
  };

  return {
    id: crypto.randomUUID(),
    ts: new Date().toISOString(),
    type: typeMap[userAction],
    taskType: taskType ?? "unknown",
    sessionId: process.env.SESSION_ID ?? "default",
    agentStrategy: process.env.AGENT_STRATEGY ?? "balanced",
    originalOutput,
    correctedOutput: userEdit,
    metadata: {},
  };
}
```

## Instinct Extraction

An instinct is an atomic, reusable behavioral rule derived from accumulated experience. Instincts are narrower than policies and broader than single-use memories. The extraction pipeline moves from raw observation to validated behavioral unit.

**Extraction pipeline:**

1. **Observation** — a learning signal is recorded with full context (task type, strategy, output, outcome)
2. **Hypothesis** — cluster similar signals; form a hypothesis about what pattern explains them ("agent uses bullet lists when prose would be better for short answers")
3. **Validation** — test the hypothesis against held-out signal history; confirm it predicts outcome
4. **Instinct formation** — encode the validated hypothesis as a named, versioned instinct with applicability conditions
5. **Confidence scoring** — assign an initial confidence score based on sample size and signal strength

**Confidence scoring for instincts:**

Confidence is a function of evidence volume, recency, and consistency. A new instinct starts at low confidence and graduates as evidence accumulates.

```
confidence = (signal_count / min_threshold) * recency_weight * consistency_rate
```

- `signal_count`: number of supporting observations
- `min_threshold`: minimum observations required for the instinct type (corrections: 3, acceptances: 5)
- `recency_weight`: exponential decay applied to older signals (lambda = 0.1 per week)
- `consistency_rate`: fraction of signals that support vs contradict the hypothesis

```python
import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal

InstinctStatus = Literal["candidate", "active", "deprecated"]

@dataclass
class Instinct:
    id: str
    description: str
    task_types: list[str]
    status: InstinctStatus
    confidence: float
    supporting_signals: int
    contradicting_signals: int
    created_at: str
    last_updated: str
    tags: list[str] = field(default_factory=list)

def compute_confidence(
    supporting: int,
    contradicting: int,
    min_threshold: int,
    oldest_signal_days: float,
    decay_lambda: float = 0.1,
) -> float:
    if supporting == 0:
        return 0.0
    volume_score = min(supporting / min_threshold, 1.0)
    recency_weight = math.exp(-decay_lambda * (oldest_signal_days / 7))
    consistency_rate = supporting / (supporting + contradicting) if (supporting + contradicting) > 0 else 0.0
    return round(volume_score * recency_weight * consistency_rate, 4)

def extract_instinct_candidate(
    signals: list[dict],
    description: str,
    task_types: list[str],
) -> Instinct:
    supporting = sum(1 for s in signals if s.get("supports_hypothesis"))
    contradicting = len(signals) - supporting
    now = datetime.now(timezone.utc).isoformat()
    oldest_days = max((datetime.now(timezone.utc) - datetime.fromisoformat(s["ts"])).days for s in signals) if signals else 0
    return Instinct(
        id=f"inst-{hash(description) % 100000:05d}",
        description=description,
        task_types=task_types,
        status="candidate",
        confidence=compute_confidence(supporting, contradicting, min_threshold=3, oldest_signal_days=oldest_days),
        supporting_signals=supporting,
        contradicting_signals=contradicting,
        created_at=now,
        last_updated=now,
    )
```

## Feedback Loop Architecture

A feedback loop connects agent output back to agent behavior. Closing the loop requires capturing signals, routing them to the learning system, updating instinct confidence, and surfacing updated instincts to the agent at inference time.

**Explicit feedback loop** — user directly signals quality:

```
Agent output → User reviews → Correction/acceptance → Signal recorder → Instinct updater → Agent context
```

**Implicit feedback loop** — downstream outcomes signal quality:

```
Agent output → Task executor → Pass/fail outcome → Attribution engine → Instinct updater → Agent context
```

**Temporal feedback loop** — long-horizon outcomes:

```
Agent decision → N-step delay → Metric evaluation → Correlation analysis → Strategy weight update
```

**Loop integrity requirements:**

- Every signal must be attributed to the specific agent decision that caused it
- Loops must not create positive feedback cycles that amplify noise (see Anti-Patterns)
- Loops must include a human-in-the-loop gate before high-confidence instincts are activated
- Temporal loops must account for confounding factors between agent decision and observed outcome

```typescript
interface FeedbackLoop {
  signalCapture: (event: LearningSignal) => Promise<void>;
  attributeSignal: (signal: LearningSignal) => Promise<string>;   // returns instinct ID
  updateConfidence: (instinctId: string, signal: LearningSignal) => Promise<Instinct>;
  shouldActivate: (instinct: Instinct) => boolean;
  surfaceInstincts: (taskType: string) => Promise<Instinct[]>;
}

function shouldActivate(instinct: Instinct): boolean {
  const CONFIDENCE_THRESHOLD = 0.7;
  const MIN_SUPPORTING = 5;
  return (
    instinct.confidence >= CONFIDENCE_THRESHOLD &&
    instinct.supporting_signals >= MIN_SUPPORTING &&
    instinct.status === "candidate"
  );
}
```

## Pattern Graduation

Pattern graduation is the promotion pipeline from raw observation to durable behavioral rule. Each stage has explicit promotion criteria. Graduation prevents premature generalization while ensuring valuable patterns reach production.

**Promotion pipeline:**

```
Observation → Instinct Candidate → Active Instinct → Behavioral Rule → Skill Update
   (raw)          (conf < 0.5)       (conf >= 0.7)    (conf >= 0.9)     (embedded)
```

**Graduation criteria by stage:**

| Stage | Confidence | Min Observations | Recency | Contradiction Rate | Human Gate |
|-------|-----------|-----------------|---------|-------------------|------------|
| Candidate | < 0.5 | 1 | Any | < 50% | No |
| Active Instinct | >= 0.7 | 5 | Within 30d | < 20% | Optional |
| Behavioral Rule | >= 0.9 | 15 | Within 14d | < 10% | Required |
| Skill Update | >= 0.95 | 30 | Within 7d | < 5% | Required |

**Recency weighting** — older signals decay in weight using exponential decay. An instinct with 20 supporting signals from 6 months ago is less reliable than one with 8 signals from the past week.

**Contradiction handling** — when a new signal contradicts an existing instinct, reduce confidence proportionally. If contradiction rate rises above the threshold for the current stage, demote the instinct one stage.

```python
def promote(instinct: Instinct, human_approved: bool = False) -> Instinct:
    """Attempt to promote instinct to next stage if criteria are met."""
    promotions = [
        ("candidate", "active", 0.7, 5, False),
        ("active", "rule", 0.9, 15, True),
        ("rule", "skill", 0.95, 30, True),
    ]
    for current, next_stage, conf_thresh, min_obs, needs_human in promotions:
        if (
            instinct.status == current
            and instinct.confidence >= conf_thresh
            and instinct.supporting_signals >= min_obs
            and (not needs_human or human_approved)
        ):
            from dataclasses import replace
            return replace(instinct, status=next_stage)
    return instinct

def handle_contradiction(instinct: Instinct, penalty: float = 0.05) -> Instinct:
    """Reduce confidence on contradicting signal; demote if threshold exceeded."""
    from dataclasses import replace
    new_confidence = max(0.0, instinct.confidence - penalty)
    new_contradicting = instinct.contradicting_signals + 1
    total = instinct.supporting_signals + new_contradicting
    contradiction_rate = new_contradicting / total if total > 0 else 0.0
    new_status = instinct.status
    if contradiction_rate > 0.2 and instinct.status in ("rule", "skill"):
        new_status = "active"
    elif contradiction_rate > 0.5 and instinct.status == "active":
        new_status = "candidate"
    return replace(instinct, confidence=new_confidence, contradicting_signals=new_contradicting, status=new_status)
```

## Memory-Backed Learning

Self-learning agents use three memory types to persist and apply learned patterns. Each memory type serves a distinct learning function.

**Episodic memory** — stores specific past experiences with context. Used for pattern mining: identify recurring situations and outcomes across stored episodes. Cross-ref: `agent-memory-patterns` episodic store design.

**Semantic memory** — stores general knowledge distilled from many episodes. Instincts and behavioral rules live here. The graduation pipeline writes to semantic memory. Cross-ref: `agent-memory-patterns` semantic retrieval.

**Procedural memory** — stores skill programs: sequences of steps proven to work for a task class. Skill-level graduations encode into procedural memory. Cross-ref: `agent-memory-patterns` procedural encoding.

```typescript
interface AgentMemoryStore {
  episodic: {
    record: (episode: Episode) => Promise<void>;
    query: (taskType: string, limit: number) => Promise<Episode[]>;
    minePatterns: (taskType: string, minOccurrences: number) => Promise<PatternCandidate[]>;
  };
  semantic: {
    getInstincts: (taskType: string) => Promise<Instinct[]>;
    upsertInstinct: (instinct: Instinct) => Promise<void>;
    deprecateInstinct: (id: string, reason: string) => Promise<void>;
  };
  procedural: {
    getSkill: (skillName: string) => Promise<Skill | null>;
    registerSkill: (skill: Skill) => Promise<void>;
  };
}

interface Episode {
  id: string;
  ts: string;
  taskType: string;
  input: string;
  output: string;
  outcome: "success" | "failure" | "correction";
  signals: LearningSignal[];
  metadata: Record<string, unknown>;
}

interface PatternCandidate {
  pattern: string;
  occurrences: number;
  taskTypes: string[];
  sampleEpisodeIds: string[];
}
```

## Safety Constraints

Unconstrained self-modification creates runaway behavior: an agent that learns from noise, amplifies bad instincts, or modifies itself too aggressively becomes unreliable. Safety constraints bound the learning rate and require human oversight at critical thresholds.

**Learning rate limits** — cap how quickly confidence can rise per time window:

- Maximum confidence increase per session: +0.1
- Maximum new instincts activated per cycle: 3
- Minimum observation window before first promotion: 7 days

**Human-in-the-loop gates** — require explicit human approval before:

- Promoting any instinct to "rule" or "skill" stage
- Deprecating an instinct with confidence > 0.8
- Activating an instinct that modifies agent persona, tone, or safety behaviors

**Rollback mechanisms** — every instinct activation must be reversible:

- Snapshot instinct state before each promotion batch
- Provide a `rollback(snapshotId)` operation that restores prior state
- Log all activations with enough context to audit why the promotion occurred

**Scope constraints** — instincts must not modify:

- Safety policies (content filtering, refusal behaviors)
- Authentication or authorization logic
- Instinct promotion thresholds themselves (no self-modifying learning rates)

```python
LEARNING_RATE_LIMITS = {
    "max_confidence_increase_per_session": 0.10,
    "max_activations_per_cycle": 3,
    "min_observation_window_days": 7,
    "forbidden_tag_prefixes": ["safety-", "auth-", "meta-learning-"],
}

def is_safe_to_promote(instinct: Instinct, session_activations: int) -> tuple[bool, str]:
    if session_activations >= LEARNING_RATE_LIMITS["max_activations_per_cycle"]:
        return False, "max activations per cycle reached"
    for prefix in LEARNING_RATE_LIMITS["forbidden_tag_prefixes"]:
        if any(tag.startswith(prefix) for tag in instinct.tags):
            return False, f"instinct tagged with protected prefix: {prefix}"
    return True, "ok"
```

## Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Overfitting to recent sessions** | Agent weights last session signals so heavily that a single unusual session overwrites reliable long-term patterns | Apply exponential decay with a long half-life (14+ days); require minimum 7-day observation window before promoting |
| **Learning from noise** | Signals from atypical tasks (user was confused, test runs, edge cases) are treated as representative | Tag signal source; exclude signals marked as anomalous or test; require multiple independent sessions |
| **Confirmation bias** | Learning system only counts supporting signals; contradictions are discarded or underweighted | Maintain and expose `contradicting_signals` count; enforce contradiction rate threshold at each stage |
| **Catastrophic forgetting** | Adding new instincts without versioning causes older, still-valid instincts to be silently overwritten | Use append-only instinct store with deprecation flags; never hard-delete; support instinct versioning |
| **Over-generalization** | Instinct extracted from narrow task type is applied to unrelated tasks because task_types field is too broad | Require explicit task_types list on every instinct; apply instincts only when task type matches exactly |
| **Positive feedback runaway** | A slightly good instinct raises confidence, gets more usage, generates more acceptance signals, raises confidence further — detached from real quality | Cap confidence increase per session; require human gate at rule promotion; periodically re-evaluate high-confidence instincts against fresh hold-out set |
| **Invisible instinct accumulation** | Hundreds of low-quality candidate instincts accumulate without cleanup, degrading retrieval quality | Set TTL on candidates (e.g., 30 days without new supporting signals → expire); enforce max candidate pool size |

## Cross-References

- `agent-self-evaluation-patterns` — confidence scoring, chain-of-thought reflection, LLM-as-judge, and eval-driven development that generate the signals self-learning consumes
- `agent-memory-patterns` — episodic, semantic, and procedural memory store designs; retrieval patterns for surfacing instincts at inference time
- `agent-orchestration-patterns` — multi-agent pipelines where learning signals flow between agent roles; feedback loop routing in orchestrated systems
