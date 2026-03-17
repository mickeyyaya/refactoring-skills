---
name: agent-orchestration-patterns
description: Use when designing or reviewing multi-agent systems — covers orchestration topologies (hierarchical, flat, pipeline, hybrid), task decomposition, parallel fan-out/fan-in execution, result aggregation, shared context propagation, agent communication protocols, failure handling, token economics, and anti-patterns with TypeScript examples
---

# Agent Orchestration Patterns

## Overview

Single agents hit hard limits: finite context windows, sequential throughput, and single-model reliability. Multi-agent systems unlock parallel execution, specialization, and fault isolation — but introduce new failure modes: coordination overhead, context duplication, inconsistent shared state, and cascading failures.

Use this guide when designing or reviewing systems where multiple AI agents coordinate, share work, or communicate results — whether agents are LLM-backed workers, rule-based processors, or hybrid pipelines. Applies to any system with a planner or orchestrator dispatching work to sub-agents.

## Quick Reference

| Pattern | Topology | When to Use | Key Risk |
|---------|----------|-------------|----------|
| Hierarchical Orchestrator | Orchestrator → N workers | Large tasks with clear decomposition | Orchestrator bottleneck; single point of failure |
| Flat Peer-to-Peer | Agents communicate directly | Negotiation, consensus, emergent behavior | Message explosion; hard to debug |
| Pipeline (Sequential) | A → B → C | Strict ordering, each stage transforms output | No parallelism; one failure halts all |
| Fan-Out / Fan-In | 1 → N parallel → 1 aggregator | Independent sub-tasks, time-sensitive results | Partial failures; aggregation complexity |
| Hybrid | Orchestrator + pipelines + peer links | Real production systems | All of the above |
| Supervisor Pattern | Monitor + restart agents | Long-running agents with known failure modes | Infinite restart loops |

## Orchestration Topologies

### Hierarchical (Orchestrator + Workers)

The planner or orchestrator decomposes a task and dispatches sub-tasks to specialized worker agents. Workers return results; orchestrator aggregates.

```
        ┌─────────────┐
        │ Orchestrator│
        └──────┬──────┘
    ┌──────────┼──────────┐
    ▼          ▼          ▼
┌───────┐ ┌───────┐ ┌───────┐
│Worker │ │Worker │ │Worker │
│  (A)  │ │  (B)  │ │  (C)  │
└───────┘ └───────┘ └───────┘
```

**Best for:** Code review pipelines (security agent, style agent, performance agent running in parallel), research tasks where an orchestrator dispatches domain-specific research agents.

**Failure mode:** Orchestrator becomes a bottleneck — all context must flow through it. If the orchestrator context window fills, the whole system stalls.

### Flat Peer-to-Peer

Agents communicate directly without a central coordinator. Common in negotiation, consensus, or emergent-behavior systems.

```
┌───────┐ ←──────→ ┌───────┐
│Agent A│           │Agent B│
└───────┘ ←──────→ └───────┘
    ↑                   ↑
    └────────→ ┌───────┐│
               │Agent C││
               └───────┘┘
```

**Best for:** Multi-perspective analysis (factual reviewer + security expert + performance reviewer each offering independent opinions), debate-style evaluation.

**Failure mode:** Message explosion — N agents each messaging N-1 others is O(N²) communication.

### Pipeline (Sequential)

Each stage consumes the output of the previous stage and produces input for the next. No parallelism; strict ordering.

```
┌───────┐    ┌───────┐    ┌───────┐    ┌───────┐
│ Scout │ →  │Builder│ →  │Auditor│ →  │Merger │
└───────┘    └───────┘    └───────┘    └───────┘
```

**Best for:** Workflows with hard data dependencies (each stage transforms output), compliance pipelines where order of operations matters.

**Failure mode:** No parallelism; one slow or failing stage halts everything downstream.

### Fan-Out / Fan-In

A dispatcher fans out to N agents running in parallel; an aggregator collects and merges results. The most common pattern for parallelizing work — see Parallel Execution for the TypeScript implementation.

```
         ┌──────────┐
         │Dispatcher│
         └────┬─────┘
    ┌─────────┼─────────┐
    ▼         ▼         ▼
┌───────┐ ┌───────┐ ┌───────┐
│Agent 1│ │Agent 2│ │Agent 3│
└───┬───┘ └───┬───┘ └───┬───┘
    └─────────┼─────────┘
              ▼
       ┌────────────┐
       │ Aggregator │
       └────────────┘
```

## Task Decomposition

Before dispatching agents, the orchestrator must split the work. Poor decomposition creates dependencies that force sequential execution and eliminates parallelism benefits.

### Dependency Analysis

Classify sub-tasks into independent vs sequential groups:

- **Independent:** can run in parallel — no sub-task consumes another's output
- **Sequential:** each sub-task depends on the previous — must run in order
- **Conditionally independent:** independent unless a condition is met (e.g., fallback path)

**Process:**
1. List all sub-tasks required to complete the goal
2. For each pair of sub-tasks, ask: "Does B need A's output to start?" If yes, draw a dependency edge.
3. Topological sort — tasks with no incoming edges can run in parallel
4. Assign parallel groups (wave 1, wave 2, ...) based on depth in the DAG

### Granularity Rules

Task size directly affects token economics and coordination overhead:

| Task Size | Lines of Output | Agents | Risk |
|-----------|----------------|--------|------|
| Too small | <50 | Many | Coordination overhead exceeds work cost |
| Appropriate | 100-500 | 3-8 | Good balance |
| Too large | >1000 | 1 | Agent exhausts context; produces low-quality output |

**Rules of thumb:**
- A sub-task should be completable within 60-70% of the agent's context window
- If a subtask requires reading more than 5 files, split it further
- Sequential dependencies inside a sub-task are fine; dependencies between sub-tasks impose ordering costs

## Parallel Execution (Fan-Out / Fan-In)

The fan-out/fan-in pattern dispatches N independent sub-tasks to N agents concurrently, then aggregates results. TypeScript `Promise.allSettled` is preferred over `Promise.all` — it allows partial success rather than aborting on the first failure.

```typescript
import { z } from "zod";

interface AgentTask {
  id: string;
  type: string;
  payload: unknown;
}

interface AgentResult<T> {
  taskId: string;
  agentId: string;
  output: T;
  tokenUsage: { prompt: number; completion: number };
  durationMs: number;
}

interface AgentError {
  taskId: string;
  agentId: string;
  error: string;
  retryable: boolean;
}

type FanOutResult<T> =
  | { status: "fulfilled"; value: AgentResult<T> }
  | { status: "rejected"; reason: AgentError };

async function dispatchAgent<T>(
  task: AgentTask,
  timeoutMs: number,
  runAgent: (task: AgentTask) => Promise<AgentResult<T>>
): Promise<AgentResult<T>> {
  const timer = new Promise<never>((_, reject) =>
    setTimeout(() => reject(new Error(`Agent timeout after ${timeoutMs}ms`)), timeoutMs)
  );
  return Promise.race([runAgent(task), timer]);
}

async function fanOut<T>(
  tasks: AgentTask[],
  runAgent: (task: AgentTask) => Promise<AgentResult<T>>,
  options: { timeoutMs?: number; minSuccessRatio?: number } = {}
): Promise<{ results: AgentResult<T>[]; errors: AgentError[]; partial: boolean }> {
  const { timeoutMs = 30_000, minSuccessRatio = 0.5 } = options;

  const settled = await Promise.allSettled(
    tasks.map(task => dispatchAgent(task, timeoutMs, runAgent))
  );

  const results: AgentResult<T>[] = [];
  const errors: AgentError[] = [];

  for (const outcome of settled) {
    if (outcome.status === "fulfilled") {
      results.push(outcome.value);
    } else {
      const err = outcome.reason as Error;
      errors.push({
        taskId: "unknown",
        agentId: "unknown",
        error: err.message,
        retryable: err.message.includes("timeout") || err.message.includes("rate limit"),
      });
    }
  }

  const successRatio = results.length / tasks.length;
  if (successRatio < minSuccessRatio) {
    throw new Error(
      `Fan-out failed: only ${results.length}/${tasks.length} agents succeeded (min ratio: ${minSuccessRatio})`
    );
  }

  return { results, errors, partial: errors.length > 0 };
}
```

**Timeout management:** Each agent gets an individual timeout. The aggregator proceeds with partial results if `minSuccessRatio` is met. This prevents one slow agent from blocking the entire workflow.

**Partial result handling:** When `partial: true`, the aggregator must decide whether to surface incomplete results or trigger a retry for failed sub-tasks only.

## Result Aggregation

After fan-in, results from N agents must be merged into a single coherent output.

### Majority Voting

For classification or boolean decisions, use majority vote. Odd agent counts prevent ties.

```typescript
function majorityVote<T extends string>(votes: T[]): { winner: T; confidence: number } {
  const counts = votes.reduce<Record<string, number>>((acc, v) => {
    acc[v] = (acc[v] ?? 0) + 1;
    return acc;
  }, {});
  const winner = Object.entries(counts).sort(([, a], [, b]) => b - a)[0][0] as T;
  return { winner, confidence: counts[winner] / votes.length };
}
```

### Quality-Weighted Merge

When agents have different specializations or confidence levels, weight results by quality score rather than counting votes equally. Quality score can come from the agent's self-reported confidence, token efficiency, or a judge agent's rating.

### Conflict Resolution

When agents produce contradictory outputs:
1. **Last-write-wins** — simplest, but loses information
2. **Field-level merge** — each agent owns specific fields; no conflicts possible
3. **Judge agent** — a third agent resolves conflicting outputs
4. **Human-in-the-loop** — flag conflicts for human review

**Red Flags:** Silent resolution without logging; no aggregation strategy defined; aggregating full outputs in orchestrator context (overflow risk).

## Shared Context and Rules

Agents in a system must share baseline rules without duplicating them into every agent's context.

### CLAUDE.md / Shared Rules Pattern

Establish a hierarchy of context inheritance:

```
SHARED CONTEXT (applies to all agents)
   └── ROLE CONTEXT (applies to agent type)
         └── TASK CONTEXT (applies to this specific invocation)
```

- **Shared context:** coding style, security rules, output format conventions, project constraints
- **Role context:** agent-specific instructions (Builder follows minimal-change principle; Auditor enforces strict pass/fail)
- **Task context:** the specific task payload, inputs, and expected outputs

This mirrors how `CLAUDE.md` at the project root sets shared rules while sub-directory `.claude/agents/<name>.md` files provide role-specific overrides.

### Layered Context Inheritance

```typescript
interface AgentContext {
  sharedRules: string;       // project-wide constraints
  roleInstructions: string;  // role-specific behavior
  taskPayload: unknown;      // this invocation's work
}

function buildAgentContext(
  sharedRules: string,
  roleInstructions: string,
  taskPayload: unknown
): AgentContext {
  // Immutable — each agent gets its own context object
  return { sharedRules, roleInstructions, taskPayload };
}
```

**Key principle:** Shared context is read-only. Agents do not modify shared rules — they produce outputs that the orchestrator decides to persist. This prevents one agent from corrupting shared state visible to all others.

### Context Versioning

When shared context changes between cycles, version it. Agents operating on stale context produce inconsistent results. Include a `contextVersion` field in the task payload so agents can detect mismatches.

## Agent Communication Protocols

### Structured JSON vs Natural Language

Structured JSON communication between agents reduces coordination errors significantly compared to natural language handoffs:

| Dimension | Natural Language | Structured JSON |
|-----------|-----------------|-----------------|
| Parsing | Requires another LLM call | Direct deserialization |
| Ambiguity | High | Low |
| Schema validation | Impossible | Zod / Pydantic |
| Debugging | Hard to diff | Machine-readable diff |
| Token cost | Higher (verbose) | Lower (compact) |

**Rule:** Agent-to-agent messages must use structured JSON. Natural language is acceptable only in `message` or `rationale` fields intended for human review.

### Message Schema Design

```typescript
const AgentMessageSchema = z.object({
  messageId: z.string().uuid(),
  fromAgent: z.string(),
  toAgent: z.string().or(z.literal("all")),
  cycle: z.number().int().positive(),
  type: z.enum(["task", "result", "error", "hint", "status"]),
  payload: z.unknown(),         // validated per type
  rationale: z.string().optional(), // human-readable explanation
  ts: z.string().datetime(),
});

type AgentMessage = z.infer<typeof AgentMessageSchema>;
```

### Handoff Protocols

When one agent hands off to another:
1. **Explicit output schema** — the receiving agent declares what it expects; the sender validates before sending
2. **Idempotent delivery** — messages include a `messageId`; receiving agent ignores duplicates
3. **Acknowledgment** — the receiver posts a status message back so the orchestrator knows the handoff succeeded
4. **Timeout on acknowledgment** — if no ACK within N seconds, orchestrator retries or reroutes

## Failure Handling

### Retry Strategies

Classify failures before retrying — retrying permanent failures wastes tokens and time.

| Failure Type | Examples | Strategy |
|-------------|----------|----------|
| Transient | Timeout, rate limit, network error | Retry with exponential backoff |
| Model error | Malformed output, schema failure | Retry with different model or prompt |
| Permanent | Invalid task spec, missing required input | Fail fast, report to orchestrator |
| Partial | Some sub-tasks succeeded | Retry only failed sub-tasks |

### Fallback Agents

When the primary agent fails after max retries, route to a fallback:
- **Simpler model fallback:** use a smaller/cheaper model that is more reliable but less capable
- **Rule-based fallback:** for well-defined tasks, a deterministic processor can replace the LLM
- **Human escalation:** for critical paths, route to a human-in-the-loop queue

### Circuit Breaker for Agents

Prevent a repeatedly failing agent from consuming tokens on every request:

```typescript
interface CircuitBreakerState {
  failures: number;
  lastFailureTs: number;
  state: "closed" | "open" | "half-open";
}

const FAILURE_THRESHOLD = 3;
const RESET_TIMEOUT_MS = 60_000;

function shouldAllowRequest(cb: CircuitBreakerState): boolean {
  if (cb.state === "closed") return true;
  if (cb.state === "open") {
    const elapsed = Date.now() - cb.lastFailureTs;
    return elapsed >= RESET_TIMEOUT_MS; // allow one probe (half-open)
  }
  return true; // half-open: allow probe
}

function recordFailure(cb: CircuitBreakerState): CircuitBreakerState {
  const failures = cb.failures + 1;
  return {
    failures,
    lastFailureTs: Date.now(),
    state: failures >= FAILURE_THRESHOLD ? "open" : "closed",
  };
}

function recordSuccess(cb: CircuitBreakerState): CircuitBreakerState {
  return { failures: 0, lastFailureTs: 0, state: "closed" };
}
```

### Graceful Degradation

When agents fail partially:
1. Return what succeeded, clearly marked as partial
2. Surface which sub-tasks failed and why
3. Allow the caller to decide: accept partial result, retry, or escalate
4. Never silently return a partial result as if it were complete

## Token Economics

Each agent in a parallel system pays the full prompt cost independently. Parallelism reduces wall-clock time but not total token spend — it often increases it.

### Cost Model for Parallel Agents

```
Total tokens = Σ (shared_context_tokens + role_tokens + task_tokens + output_tokens) per agent
```

For N agents sharing M tokens of context:
- Sequential: `M + N * task_tokens + N * output_tokens`
- Parallel: `N * M + N * task_tokens + N * output_tokens`

Parallelism multiplies shared context cost by N. For large shared contexts, this can exceed the sequential cost even accounting for wall-clock savings.

### When Parallelism Saves vs Wastes Tokens

| Scenario | Use Parallel? | Reason |
|----------|-------------|--------|
| 10 independent tasks, small shared context | Yes | Linear cost, N× speedup |
| 3 tasks, large shared context (>50k tokens) | Maybe | Context cost dominates; evaluate tradeoff |
| Tasks with strong dependencies | No | Parallelism provides no speedup |
| Majority voting requires 5 agents | Yes if accuracy critical | Extra tokens justified by reliability gain |
| Single task, no decomposition possible | No | Overhead with no benefit |

**Rule:** Measure total tokens for the sequential baseline. If parallel cost exceeds 2× sequential cost without a proportional quality or latency benefit, use sequential.

## Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Chatty Agents** | Agents exchange many small messages to coordinate — each message requires an LLM call | Batch coordination into fewer, larger structured messages; use a shared state store instead of message passing |
| **Orchestrator Bottleneck** | All agent outputs flow through the orchestrator's context — large outputs fill it quickly | Agents write to shared storage; orchestrator reads summaries, not full outputs |
| **Context Duplication** | Each agent receives the full shared context even when only a subset is relevant | Use role-based context slicing — each agent receives only the shared rules relevant to its role |
| **Agent Sprawl** | Too many specialized agents for simple tasks — coordination overhead exceeds task cost | Apply the granularity rules; consolidate agents with overlapping responsibilities |
| **Implicit Output Schema** | Agents return natural language; downstream agents parse it with another LLM call | Define explicit JSON schemas for all agent outputs; validate before consuming |
| **No Failure Budget** | System requires 100% agent success — one failure halts everything | Define minimum success ratio per fan-out; design for partial results |
| **Recursive Orchestration** | Orchestrator spawns sub-orchestrators without depth limit — stack overflow equivalent | Set max orchestration depth (2-3 levels typical); flatten deep hierarchies |
| **Shared Mutable State** | Agents write to a shared store concurrently without coordination — race conditions | Use immutable writes with versioning; implement optimistic locking or event sourcing |

## Cross-References

- `agent-memory-patterns` — how agents persist and retrieve context across cycles; shared memory stores for multi-agent systems
- `agent-self-evaluation-patterns` — how individual agents assess their own output quality before handing off; confidence scoring and self-critique loops
- `ai-ml-integration-patterns` — LLM API error handling, token budget management, structured output validation; the primitives each agent uses internally
- `concurrency-patterns` — Promise.allSettled patterns, mutex and semaphore primitives, race condition prevention; applies to fan-out/fan-in coordination
- `error-handling-patterns` — retry with exponential backoff, circuit breaker primitives; referenced in Failure Handling section
- `message-queue-patterns` — durable message delivery, dead-letter queues; applies when agent communication requires reliability guarantees
