---
name: agent-token-optimization-patterns
description: Use when designing or reviewing AI agent systems for cost and latency efficiency — covers context engineering (write/select/compress/isolate), prompt caching strategies, model routing by complexity, token budget management, context window techniques, prompt compression, and anti-patterns with TypeScript and Python examples
---

# Agent Token Optimization Patterns

## Overview

Token = cost + latency. Every token you can save without losing quality is pure value — lower bills, faster responses, and more headroom before context limits bite. At scale, unoptimized agents burn 3-10× more tokens than necessary, primarily through context stuffing, wrong-model routing, and cache thrashing.

Token optimization is not about cutting corners. It is about precision: sending exactly the information the model needs, in exactly the right form, to the right model, at the right time.

## Quick Reference

| Technique | Token Savings | Implementation Complexity | Risk |
|-----------|--------------|--------------------------|------|
| Prompt caching (stable content first) | 45-80% on cache hit | Low | Cache thrashing if content rotates |
| Model routing (haiku for simple tasks) | 60-90% cost reduction | Medium | Quality degradation on misrouted tasks |
| Structured data over prose | 20-40% | Low | Schema design overhead |
| Progressive summarization | 30-60% | Medium | Lossy compression of earlier context |
| System prompt deduplication | 10-30% | Low | Divergence if copies drift out of sync |
| Context slicing (role-based) | 20-50% | Medium | Missing context if slices are too narrow |
| Sliding window (drop oldest turns) | Variable | Low | Loss of early conversation context |
| Spawn new agent vs stuff context | High (resets window) | High | Coordination overhead, handoff cost |

## Context Engineering

Context engineering is the systematic practice of controlling what goes into an agent's context window. The framework has four operations: **Write, Select, Compress, Isolate**.

### Write — Craft Precise Prompts

Write prompts that express the task in minimum tokens without ambiguity. Prefer imperative verbs over explanatory prose. Replace "Could you please help me understand..." with "Explain:". Remove politeness markers, hedges, and meta-commentary — the model does not need them.

```typescript
// WRONG: verbose and hedging
const verbose = `
  I was wondering if you could help me take a look at the following code
  and maybe identify any potential issues that might be present in it.
  Please be thorough but also concise in your response if possible.
`;

// CORRECT: imperative, direct
const precise = `Review this code. List issues by severity (critical/high/medium/low). One line each.`;
```

**Rules:**
- One instruction per sentence
- State the output format explicitly (JSON, numbered list, one line per item)
- Omit background context the model already has from its training data
- Remove examples unless the task is genuinely ambiguous without them

### Select — Choose Relevant Context

Do not inject the entire codebase or conversation history. Select only what is directly relevant to the current task.

```python
def select_context(files: list[str], task_keywords: list[str]) -> list[str]:
    """Return only files that contain at least one task keyword."""
    relevant = []
    for path in files:
        content = read_file(path)
        if any(kw.lower() in content.lower() for kw in task_keywords):
            relevant.append(path)
    return relevant[:5]  # Hard cap: never inject more than 5 files per task
```

**Selection heuristics:**
- For code tasks: include the file being changed + direct imports only
- For Q&A tasks: include the most recent N turns, not the full history
- For multi-step workflows: pass only the output of the previous step, not all prior steps
- Use semantic similarity search to rank and trim candidate context chunks

### Compress — Reduce Token Count

When context cannot be excluded, compress it. Replace full file contents with structured summaries. Replace conversation history with a rolling summary.

```typescript
interface ContextSummary {
  type: "file" | "conversation" | "result";
  path?: string;
  summary: string;         // compressed representation
  tokenEstimate: number;   // approximate tokens saved
  fullContentAvailable: boolean;
}

function compressFileContext(path: string, content: string): ContextSummary {
  // Replace full content with: exports, function signatures, type definitions
  const lines = content.split("\n");
  const signatures = lines.filter(l =>
    l.match(/^(export|function|class|interface|type|const\s+\w+\s*=\s*(async\s*)?\()/)
  );
  return {
    type: "file",
    path,
    summary: signatures.join("\n"),
    tokenEstimate: content.length - signatures.join("\n").length,
    fullContentAvailable: true,
  };
}
```

### Isolate — Separate Concerns into Agents

When a task has multiple independent concerns, spawn separate agents rather than injecting all context into one. Each agent receives only its relevant slice.

```
Single agent (bad):  [security context] + [style context] + [perf context] + [code] → one agent
Isolated (good):     [security context] + [code] → agent A
                     [style context]    + [code] → agent B
                     [perf context]     + [code] → agent C
```

Isolation reduces per-agent context by 60-70% while enabling parallelism. The tradeoff is coordination overhead — only isolate when sub-tasks are genuinely independent.

## Prompt Caching

Most LLM APIs (Anthropic, OpenAI) support prompt caching: if the prefix of a request matches a cached prefix, the cached KV computation is reused and only the suffix is processed at full cost.

### Cache Placement Rules

**Place stable content first, volatile content last.** The cache prefix must match exactly — any change before the cached boundary invalidates the entire cache.

```
CACHE-FRIENDLY layout:
  [System prompt — never changes]
  [Tool definitions — rarely change]
  [Examples — change per task type]
  [Conversation history — changes each turn]  ← volatile, goes last
  [Current user message]                       ← most volatile

CACHE-UNFRIENDLY layout:
  [Timestamp or request ID]     ← volatile, poisoned the cache
  [System prompt]
  [Task]
```

```python
def build_cache_optimized_request(
    system_prompt: str,       # stable — injected first
    tool_definitions: list,   # stable — injected second
    conversation_history: list, # changes each turn
    current_message: str,     # most volatile
) -> dict:
    return {
        "system": system_prompt,
        "tools": tool_definitions,
        "messages": [
            *conversation_history,
            {"role": "user", "content": current_message},
        ],
    }
```

### TTL Strategies

Cache entries have a TTL (typically 5 minutes for Anthropic). Strategies to maximize cache hit rate:

- **Batch requests:** group requests with the same system prompt into short time windows
- **Stable system prompts:** never include dynamic data (timestamps, request IDs) in the cached prefix
- **Shared definitions:** consolidate tool definitions and shared rules into one canonical block reused across all agents in a workflow
- **Session pinning:** route requests from the same session to the same backend node when the provider supports session affinity

### Cache Hit Optimization

Track cache hit rates and alert when they drop below threshold:

```typescript
interface CacheMetrics {
  inputTokens: number;
  cachedInputTokens: number;
  outputTokens: number;
}

function cacheHitRate(metrics: CacheMetrics): number {
  if (metrics.inputTokens === 0) return 0;
  return metrics.cachedInputTokens / metrics.inputTokens;
}

function assertCacheHealth(metrics: CacheMetrics, minHitRate = 0.4): void {
  const rate = cacheHitRate(metrics);
  if (rate < minHitRate) {
    console.warn(`Cache hit rate ${(rate * 100).toFixed(1)}% below threshold ${minHitRate * 100}%. Check prompt stability.`);
  }
}
```

### When Caching Hurts

- **Rapidly rotating prompts:** if the system prompt changes on every request, caching adds overhead without benefit
- **Single-use agents:** a one-shot agent with a unique prompt never benefits from caching
- **Very short prompts:** the cache lookup cost can exceed the recompute cost for prompts under ~200 tokens

## Model Routing

Not every task needs the most powerful model. Route to the cheapest model that can reliably complete the task.

### Routing Table

| Model | Use For | Avoid For |
|-------|---------|-----------|
| Haiku 4.5 | Classification, extraction, formatting, simple Q&A, worker agents with narrow scope | Multi-step reasoning, code generation, ambiguous tasks |
| Sonnet 4.6 | Standard code generation, analysis, orchestration, most production tasks | Tasks requiring maximum depth of reasoning |
| Opus 4.5 | Architectural decisions, complex debugging, research synthesis, maximum accuracy required | High-volume, latency-sensitive, cost-sensitive pipelines |

### Complexity Estimation Heuristics

Estimate task complexity before routing:

```typescript
type ModelTier = "haiku" | "sonnet" | "opus";

interface TaskSignals {
  inputTokens: number;
  requiresCodeGen: boolean;
  requiresMultiStepReasoning: boolean;
  hasAmbiguousRequirements: boolean;
  isClassificationOrExtraction: boolean;
  priorFailureCount: number;
}

function routeToModel(signals: TaskSignals): ModelTier {
  if (signals.priorFailureCount >= 2) return "opus"; // escalate on repeated failures

  if (signals.isClassificationOrExtraction && !signals.requiresCodeGen) {
    return "haiku";
  }

  if (signals.requiresMultiStepReasoning || signals.hasAmbiguousRequirements) {
    return "opus";
  }

  if (signals.inputTokens > 50_000) return "sonnet"; // large context → sonnet
  if (signals.requiresCodeGen) return "sonnet";

  return "haiku";
}
```

### Fallback Chains

Route through increasingly capable models on failure:

```python
FALLBACK_CHAIN = ["haiku", "sonnet", "opus"]

async def route_with_fallback(task: dict, starting_tier: str) -> dict:
    start_idx = FALLBACK_CHAIN.index(starting_tier)
    for tier in FALLBACK_CHAIN[start_idx:]:
        result = await call_model(tier, task)
        if result["valid"]:
            return result
        # log that we escalated
    raise RuntimeError("All model tiers failed")
```

## Token Budget Management

Agents without budgets will consume unbounded tokens. Define budgets at both the task level and the cycle level.

### Per-Task Budgets

```typescript
interface TokenBudget {
  inputCap: number;        // max tokens in prompt
  outputCap: number;       // max tokens in completion
  softWarnAt: number;      // warn but continue (as fraction of cap, e.g. 0.8)
  hardStopAt: number;      // abort task (as fraction of cap, e.g. 1.0)
}

const DEFAULT_BUDGETS: Record<string, TokenBudget> = {
  "code-review":      { inputCap: 8_000,  outputCap: 2_000, softWarnAt: 0.8, hardStopAt: 1.0 },
  "summarization":    { inputCap: 50_000, outputCap: 1_000, softWarnAt: 0.8, hardStopAt: 1.0 },
  "code-generation":  { inputCap: 10_000, outputCap: 4_000, softWarnAt: 0.8, hardStopAt: 1.0 },
  "orchestration":    { inputCap: 20_000, outputCap: 3_000, softWarnAt: 0.8, hardStopAt: 1.0 },
};

function checkBudget(budget: TokenBudget, usedInput: number, usedOutput: number): "ok" | "warn" | "stop" {
  const inputRatio = usedInput / budget.inputCap;
  const outputRatio = usedOutput / budget.outputCap;
  const ratio = Math.max(inputRatio, outputRatio);
  if (ratio >= budget.hardStopAt) return "stop";
  if (ratio >= budget.softWarnAt) return "warn";
  return "ok";
}
```

### Per-Cycle Budgets

Track cumulative spend across all agents in a workflow cycle:

```python
class CycleBudget:
    def __init__(self, cycle_cap_tokens: int):
        self._cap = cycle_cap_tokens
        self._used = 0

    def consume(self, tokens: int) -> None:
        self._used += tokens
        if self._used > self._cap:
            raise BudgetExceededError(f"Cycle budget {self._cap} exceeded at {self._used}")

    @property
    def remaining(self) -> int:
        return max(0, self._cap - self._used)

    @property
    def utilization(self) -> float:
        return self._used / self._cap
```

## Context Window Management

### Progressive Summarization

As conversation history grows, replace older turns with compressed summaries:

```
Turn 1-10:   [full text]
Turn 11-20:  [summary: "User debugged auth module. Fixed JWT expiry bug. Tests pass."]
Turn 21-30:  [summary: "Refactored UserService. Introduced repository pattern."]
Turn 31+:    [full text — most recent, highest relevance]
```

Summarize when context exceeds 60% of the model's window. Keep the most recent 10-20 turns verbatim; summarize everything older.

### Sliding Window

For conversation agents, retain only the last N turns:

```typescript
function applySlideWindow<T>(history: T[], maxTurns: number): T[] {
  if (history.length <= maxTurns) return history;
  return history.slice(history.length - maxTurns);
}
```

Use with a sticky system-prompt header that summarizes any dropped context so the model is not confused by missing references.

### Tiered Context Loading

Load context in tiers — inject higher tiers only when lower tiers are insufficient:

| Tier | Content | When to Load |
|------|---------|--------------|
| 0 | Task description + output schema | Always |
| 1 | Direct file references | When task references specific files |
| 2 | Related module summaries | When direct files import other modules |
| 3 | Full related files | When summaries are insufficient |
| 4 | Full codebase | Rarely — last resort |

### Spawn New Agent vs Stuff More Context

When a task grows beyond 70% of the context window, choose:

- **Stuff more context** when: the task is nearly complete, context is highly interdependent, and spinning up a new agent would require duplicating most of the existing context
- **Spawn new agent** when: the remaining work is decomposable, earlier context is mostly resolved state that can be summarized cheaply, or the current agent has accumulated a long chain of failed attempts

## Prompt Compression Techniques

### System Prompt Deduplication

Store one canonical system prompt shared across all agents. Do not copy-paste it into each agent's definition — divergent copies will drift and cause inconsistent behavior.

```
// Good: agents reference shared rules by path or ID
sharedRules: "file:///claude/evolve/shared-rules.md"

// Bad: each agent has its own copy
agentA: { systemPrompt: "You are a code reviewer. Always be thorough..." }
agentB: { systemPrompt: "You are a code reviewer. Always be thorough..." }  // drifted copy
```

### Abbreviation Conventions

Define abbreviations in the system prompt, then use them consistently:

```
Abbreviations used in this session:
TS = TypeScript, FE = function expression, RT = return type, CB = callback
```

After establishing abbreviations, downstream prompts can use them freely. Saves 5-15% on repetitive technical content.

### Structured Data over Prose

Prose descriptions of data are 3-5× more verbose than structured equivalents:

```
// Prose: ~80 tokens
"The user has the name John Smith, they are 34 years old, their email is john@example.com,
and they have been active on the platform since January 2022."

// Structured: ~20 tokens
{"name":"John Smith","age":34,"email":"john@example.com","since":"2022-01"}
```

Use JSON or YAML for data payloads. Reserve prose for rationale and explanations.

### XML/JSON Tag Optimization

XML tags add structure but cost tokens. Use short tag names for high-frequency patterns:

```xml
<!-- Verbose: 12 tokens of overhead per block -->
<code_block language="typescript">...</code_block>

<!-- Compact: 6 tokens of overhead per block -->
<c lang="ts">...</c>
```

Define tag conventions in the system prompt. For schemas with many fields, prefer flat JSON over nested XML.

## Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Context Stuffing** | Injecting entire files, full conversation history, or unfiltered search results into every prompt | Apply the Select operation from context engineering; use tiered context loading |
| **Cache Thrashing** | Including timestamps, request IDs, or session-specific data in the cached prefix of prompts | Move volatile content to the end of the prompt; keep the cached prefix deterministic |
| **Wrong Model for Task** | Using Opus for simple classification or Haiku for complex multi-step reasoning | Implement complexity-based routing with the routing table; escalate on failure |
| **Budget-less Agents** | Agents with no input/output token caps — a single runaway agent can exhaust a day's budget | Define per-task and per-cycle budgets; enforce hard stops |
| **Premature Compression** | Compressing context so aggressively that the model loses necessary information and produces wrong results | Compress only content older than N turns; keep direct task references verbatim |
| **Duplicate System Prompts** | Copy-pasting the system prompt into every agent definition — copies drift and create inconsistencies | Store one canonical shared rules file; agents reference it by path |
| **Ignored Cache Metrics** | Never measuring cache hit rates — silent waste from misconfigured prompt ordering | Log `cachedInputTokens` and alert when hit rate drops below 40% |
| **Single Agent for Everything** | Routing all tasks through one large powerful agent to avoid routing complexity | Use model routing and isolation; smaller focused agents are cheaper and often more reliable |

## Cross-References

- `agent-orchestration-patterns` — parallel fan-out cost model (context cost multiplies by N agents), context inheritance hierarchy (shared/role/task layers), and token economics of sequential vs parallel execution
- `ai-ml-integration-patterns` — LLM API error handling, structured output validation, retry strategies; the primitives that token budget enforcement integrates with
- `agent-memory-patterns` — how progressive summarization interfaces with persistent memory stores; tiered context loading for long-running agents that recall prior sessions
