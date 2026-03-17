---
name: agent-memory-patterns
description: Use when designing or reviewing AI agent memory systems — covers memory type taxonomy (short-term, working, long-term), episodic vs semantic vs procedural memory, embedding-based retrieval with recency and importance weighting, memory compression and consolidation, cross-agent memory sharing, and anti-patterns like infinite context stuffing and stale memory poisoning, with examples in TypeScript and Python
---

# Agent Memory Patterns

## Overview

Memory is the foundation of agent intelligence. Without structured memory, agents repeat mistakes, lose context across sessions, and cannot build compound knowledge over time. A well-designed memory system determines what the agent remembers, how it retrieves relevant context, and when it safely forgets.

**When to use:** Designing a stateful AI agent or autonomous workflow; reviewing agent code for context management; evaluating retrieval latency or cost; any system where an agent must persist knowledge across conversation turns, sessions, or agent boundaries.

## Quick Reference

| Memory Type | Storage | Retrieval Strategy | Lifetime | Use Case |
|-------------|---------|-------------------|---------|---------|
| Short-term | Context window (in-memory) | Direct inclusion — no retrieval needed | Single session | Active conversation, current task state |
| Working | Scratchpad / todo file | Sequential read — agent writes and reads directly | Task duration | Reasoning steps, partial results, sub-goals |
| Long-term episodic | Vector DB with timestamps | Embedding similarity + recency weighting | Months to permanent | Past interactions, specific sessions, event log |
| Long-term semantic | Structured store / knowledge graph | Keyword or concept-graph traversal | Permanent until invalidated | Facts, entities, domain knowledge |
| Procedural | File store / instinct YAML | Template match on task type | Permanent | Reusable patterns, learned workflows, instincts |

## Memory Type Taxonomy

### Short-term Memory (Context Window)

Short-term memory is the active context window — everything currently visible to the model. It is the fastest and most reliable form of retrieval because no lookup is required.

**Capacity constraint:** Modern models support 8K–200K tokens, but the effective working range for coherent reasoning is typically 20–50K tokens. Beyond that, attention degrades on early content ("lost in the middle" problem).

**Management strategy:** Use a token budget allocator that reserves slots for system prompt, tool definitions, recent history, and retrieved context. Drop oldest turns first when the budget is exceeded.

```typescript
interface ContextBudget {
  readonly totalTokens: number;
  readonly systemReserve: number;
  readonly toolReserve: number;
  readonly historyBudget: number;
  readonly retrievedContextBudget: number;
}

function allocateContextBudget(modelLimit: number): ContextBudget {
  return {
    totalTokens: modelLimit,
    systemReserve: Math.floor(modelLimit * 0.05),      // 5% — system prompt
    toolReserve: Math.floor(modelLimit * 0.10),         // 10% — tool definitions
    historyBudget: Math.floor(modelLimit * 0.35),       // 35% — recent turns
    retrievedContextBudget: Math.floor(modelLimit * 0.40), // 40% — retrieved memory
    // remaining 10% reserved for output
  };
}
```

### Working Memory (Scratchpad)

Working memory is a mutable scratchpad where the agent records intermediate reasoning, partial results, and sub-goals during a task. It is separate from both the conversation history and long-term storage.

**Pattern:** Write working memory to a dedicated file or structured field. The agent reads it at each step, updates it, and discards it when the task completes. This prevents scratchpad noise from polluting long-term memory.

```python
from dataclasses import dataclass, field
from datetime import datetime

@dataclass
class WorkingMemory:
    task_id: str
    goal: str
    sub_goals: list[str] = field(default_factory=list)
    completed_steps: list[str] = field(default_factory=list)
    current_step: str = ""
    notes: list[str] = field(default_factory=list)
    created_at: str = field(default_factory=lambda: datetime.utcnow().isoformat())

    def add_step(self, step: str) -> "WorkingMemory":
        """Immutable update — returns new instance."""
        return WorkingMemory(
            task_id=self.task_id,
            goal=self.goal,
            sub_goals=self.sub_goals,
            completed_steps=[*self.completed_steps, self.current_step] if self.current_step else self.completed_steps,
            current_step=step,
            notes=self.notes,
            created_at=self.created_at,
        )
```

### Long-term Memory (Persistent Store)

Long-term memory persists across sessions. It requires explicit write, index, and retrieval operations. Divide long-term memory by type to avoid retrieval noise:

- **Episodic** — timestamped event log of specific agent experiences
- **Semantic** — distilled facts and knowledge extracted from episodes
- **Procedural** — learned action sequences and reusable patterns

## Episodic vs Semantic vs Procedural Memory

### Episodic Memory

Episodic memory stores specific experiences with their original context and timestamp. Retrieve it when the agent needs to recall "what happened last time in a similar situation."

**Storage format:** Vector embedding of the event description + metadata (timestamp, session ID, outcome, tags). Use recency-weighted retrieval — recent episodes are more relevant unless the query is explicitly historical.

**Before (no episodic memory):**
```
User: "Why did the last deployment fail?"
Agent: "I don't have information about previous deployments."
```

**After (episodic retrieval):**
```
User: "Why did the last deployment fail?"
Agent retrieves: episode "deploy-2024-11-14 — database migration timeout, rollback triggered"
Agent: "The deployment on Nov 14 failed due to a database migration timeout after 120s..."
```

```typescript
interface EpisodicMemory {
  readonly id: string;
  readonly sessionId: string;
  readonly timestamp: string;       // ISO-8601
  readonly description: string;     // what happened
  readonly outcome: "success" | "failure" | "partial";
  readonly tags: readonly string[];
  readonly embedding?: readonly number[];
}

async function storeEpisode(
  store: VectorStore,
  episode: Omit<EpisodicMemory, "id" | "embedding">
): Promise<EpisodicMemory> {
  const embedding = await embedText(episode.description);
  const id = `ep-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const record = { ...episode, id, embedding };
  await store.upsert({ id, vector: embedding, metadata: record });
  return record;
}
```

### Semantic Memory

Semantic memory stores abstracted, stable facts extracted from multiple episodes. It has no timestamp-based decay — it changes only when explicitly updated or invalidated.

**Storage format:** Structured key-value or graph nodes. Retrieval is by keyword match or concept traversal, not embedding similarity. Prefer deterministic lookup over approximate search for facts.

**Example:** After 10 deployment episodes, the agent consolidates: "Fact: migrations over 100 rows require the --timeout=300 flag." This fact is stored as semantic memory and retrieved on all future deployment tasks.

### Procedural Memory

Procedural memory stores learned action sequences: templates, scripts, instincts, and decision trees that encode "how to do X."

**Storage format:** YAML or JSON templates with selector patterns. Retrieval matches the current task type against stored selectors.

**Example:**
```yaml
selector: "deploy.*kubernetes|k8s.*deploy"
procedure: |
  1. Run pre-flight checks: kubectl get nodes, check resource quotas
  2. Apply manifests: kubectl apply -f manifests/ --dry-run=client
  3. Monitor rollout: kubectl rollout status deployment/<name>
  4. On failure: kubectl rollout undo deployment/<name>
learned_from_cycles: [14, 19, 23]
success_rate: 0.91
```

## Retrieval Architecture

### Embedding-based Retrieval

Convert both stored memories and the current query to dense vectors using the same embedding model. Rank candidates by cosine similarity. Always use the same model at index time and query time — a mismatch produces nonsensical rankings.

```python
from dataclasses import dataclass
import numpy as np

@dataclass
class RetrievedMemory:
    memory_id: str
    content: str
    score: float           # composite score, not raw similarity
    similarity: float      # raw cosine similarity
    recency_score: float
    importance_score: float

def compute_composite_score(
    similarity: float,
    recency_score: float,    # 0–1, 1 = very recent
    importance: float,       # 0–1, set at write time
    weights: tuple[float, float, float] = (0.5, 0.3, 0.2),
) -> float:
    """Weighted combination of relevance, recency, and importance."""
    w_sim, w_rec, w_imp = weights
    return w_sim * similarity + w_rec * recency_score + w_imp * importance

def recency_score(timestamp_iso: str, half_life_days: float = 30.0) -> float:
    """Exponential decay: score = 0.5^(age / half_life). Range: (0, 1]."""
    from datetime import datetime, timezone
    age_days = (datetime.now(timezone.utc) - datetime.fromisoformat(timestamp_iso)).days
    return 0.5 ** (age_days / half_life_days)
```

### Hybrid Search (Keyword + Vector)

Pure vector search misses exact matches (proper nouns, IDs, code symbols). Pure keyword search misses semantic variants. Hybrid search combines both with a reciprocal rank fusion step.

```typescript
interface HybridSearchResult {
  readonly id: string;
  readonly content: string;
  readonly vectorRank: number;
  readonly keywordRank: number;
  readonly fusedScore: number;
}

function reciprocalRankFusion(
  vectorResults: Array<{ id: string; content: string }>,
  keywordResults: Array<{ id: string; content: string }>,
  k = 60
): HybridSearchResult[] {
  const scores = new Map<string, { vectorRank: number; keywordRank: number; content: string }>();

  vectorResults.forEach(({ id, content }, i) => {
    scores.set(id, { vectorRank: i + 1, keywordRank: Infinity, content });
  });
  keywordResults.forEach(({ id, content }, i) => {
    const existing = scores.get(id) ?? { vectorRank: Infinity, keywordRank: Infinity, content };
    scores.set(id, { ...existing, keywordRank: i + 1, content });
  });

  return Array.from(scores.entries())
    .map(([id, { vectorRank, keywordRank, content }]) => ({
      id, content, vectorRank, keywordRank,
      fusedScore: 1 / (k + vectorRank) + 1 / (k + keywordRank),
    }))
    .sort((a, b) => b.fusedScore - a.fusedScore);
}
```

Cross-reference: `ai-ml-integration-patterns` — RAG pipeline for embedding, chunking, and context window packing.

## Memory Compression and Consolidation

### Progressive Summarization

Rather than storing every interaction verbatim, progressively summarize: first pass extracts key facts, second pass distills to a single paragraph, third pass produces a single sentence. Each level trades detail for density.

**Consolidation trigger:** Run consolidation when: (1) episodic memory store exceeds N entries, (2) the agent is idle, or (3) a time-based schedule fires (e.g., end of session).

```python
async def consolidate_episodes(
    episodes: list[dict],
    llm_client,
    min_episodes_to_consolidate: int = 10,
) -> dict:
    """Consolidate a batch of episodes into a single semantic memory record."""
    if len(episodes) < min_episodes_to_consolidate:
        return {}  # not enough to consolidate
    episode_texts = "\n\n".join(
        f"[{ep['timestamp']}] {ep['description']} (outcome: {ep['outcome']})"
        for ep in sorted(episodes, key=lambda e: e["timestamp"])
    )
    response = await llm_client.complete(
        system="Extract stable facts from these agent episodes. Output JSON: "
               '{"facts": [str], "patterns": [str], "tags": [str]}',
        user=episode_texts,
    )
    return {"source_episode_ids": [e["id"] for e in episodes], **response}
```

### Hierarchical Compression

Maintain three tiers of memory compression:
1. **Raw episodes** — full event log, kept for 30 days, high storage cost
2. **Session summaries** — one summary per session, kept for 6 months
3. **Distilled facts** — permanent semantic records, updated on contradiction

Never delete the distilled tier automatically — it requires explicit invalidation when facts change.

## Cross-Agent Memory Sharing

### Shared Context Bus

Multiple agents can share a common memory namespace through a bus pattern. Each agent writes memories tagged with its agent ID and a visibility tier.

```typescript
type MemoryVisibility = "private" | "team" | "global";

interface SharedMemoryRecord {
  readonly id: string;
  readonly agentId: string;
  readonly namespace: string;       // e.g., "project:auth-module"
  readonly visibility: MemoryVisibility;
  readonly content: string;
  readonly embedding: readonly number[];
  readonly createdAt: string;
}

async function writeSharedMemory(
  store: VectorStore,
  agentId: string,
  namespace: string,
  content: string,
  visibility: MemoryVisibility = "team"
): Promise<void> {
  const embedding = await embedText(content);
  await store.upsert({
    id: `${agentId}-${Date.now()}`,
    vector: embedding,
    metadata: { agentId, namespace, visibility, content, createdAt: new Date().toISOString() },
  });
}

async function querySharedMemory(
  store: VectorStore,
  queryEmbedding: number[],
  requestingAgentId: string,
  namespace: string
): Promise<SharedMemoryRecord[]> {
  const results = await store.query({
    vector: queryEmbedding,
    filter: { namespace, visibility: { $in: ["global", "team"] } },
    topK: 10,
  });
  return results.filter(r => r.metadata.agentId === requestingAgentId || r.metadata.visibility !== "private");
}
```

### Conflict Resolution

When two agents write conflicting facts to semantic memory, apply last-write-wins by default but flag the conflict for human review if confidence scores are both above 0.85.

Cross-reference: `agent-self-evaluation-patterns` — confidence scoring used to weight memory contributions from multiple agents.

## Memory Lifecycle

The full lifecycle of a memory record:

1. **Creation** — agent writes a new memory with content, tags, importance score (0–1), and visibility
2. **Indexing** — embed content, store vector + metadata in the persistent store
3. **Retrieval** — hybrid search returns candidates, scored by composite (similarity + recency + importance)
4. **Use** — retrieved content injected into context window; retrieval event logged (for access-based importance boosting)
5. **Decay** — recency score degrades exponentially over time; low-composite memories become invisible to retrieval without being deleted
6. **Consolidation** — episodic memories are periodically merged into semantic summaries; raw episodes archived
7. **Archival** — memories below a composite threshold move to cold storage (accessible but not returned in hot retrieval)
8. **Deletion** — explicit deletion only for PII compliance or explicit invalidation; never automatic for semantic tier

## Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Infinite context stuffing** | Injecting all retrieved memories into the context window without a token budget — exceeds model limit or degrades coherence | Enforce a hard token cap on retrieved context; rank and truncate to top-K within budget |
| **Never-forgetting** | Storing every interaction verbatim with no consolidation or decay — storage explodes; retrieval returns stale noise | Implement progressive summarization and recency-weighted scoring; archive old episodic records |
| **Stale memory poisoning** | Old facts retrieved and injected without checking if they are still valid — agent acts on outdated information | Tag memories with invalidation conditions; run a freshness check before injecting high-stakes semantic facts |
| **Memory without retrieval strategy** | Writing memories but always injecting the full store into context — defeats the purpose of a memory system | Define retrieval criteria at write time: what query should surface this memory? Test retrieval before deploying |
| **Cross-agent memory collision** | Multiple agents write to the same namespace with no visibility tiers — agents override each other's context | Namespace memories by agent and project; enforce visibility tiers; use conflict detection on high-confidence writes |
| **Embedding model mismatch** | Documents indexed with model A, queries run with model B — similarity scores are meaningless | Lock the embedding model version in config; re-index if the model changes |
| **Single-tier compression** | All memories stored at full fidelity — token cost scales with history length | Use three-tier compression: raw episodes, session summaries, distilled facts |

Cross-reference: `caching-strategies` — TTL and eviction strategies applicable to memory tier management.
Cross-reference: `agent-self-evaluation-patterns` — self-evaluation patterns for validating memory retrieval quality.
Cross-reference: `ai-ml-integration-patterns` — RAG pipeline, token budget management, and embedding patterns.

## Cross-References

- `ai-ml-integration-patterns` — RAG pipeline design, embedding patterns, and token budget management reused directly in the retrieval architecture
- `agent-self-evaluation-patterns` — confidence scoring and LLM-as-Judge patterns used to validate and weight memory contributions
- `caching-strategies` — TTL, eviction, and tiered-cache patterns that map directly to the memory lifecycle (hot/warm/cold tiers)
- `observability-patterns` — trace memory retrieval latency, cache hit rate, and embedding model calls as spans
