---
name: agent-shared-values-patterns
description: Use when designing multi-agent systems that must share consistent rules, values, and constraints across all agents — covers layered inheritance models, the CLAUDE.md pattern, override resolution, consistency enforcement, value propagation in parallel agents, conflict detection, and anti-patterns with TypeScript and Python examples
---

# Agent Shared Values Patterns

## Overview

In multi-agent systems, consistent behavior requires shared rules propagated to every agent. Without explicit propagation, each agent operates on its own assumptions — producing drift, contradictions, and unpredictable outputs as the team scales.

Shared values are the baseline commitments every agent must honor: coding style, security constraints, output formats, immutability rules, error handling policies. Propagating them correctly means each agent enforces them without needing to rediscover them from scratch, without duplicating them into every prompt, and without allowing one agent's override to silently break another's behavior.

Use this guide when: adding a new agent to an existing team, designing context injection for parallel fan-out, debugging behavioral inconsistencies across agents, or building an enforcement layer that validates agent outputs against shared rules.

## Quick Reference

| Layer | Scope | Override Rules | Validation |
|-------|-------|----------------|------------|
| Global | All agents, all projects | Cannot be removed; only extended | Required on every agent invocation |
| Project | All agents in one project | Can extend global; cannot contradict | Checked at project initialization |
| Role | Single agent type (e.g., Builder) | Can extend project; must document overrides | Checked when agent is instantiated |
| Task | One specific invocation | Narrow task-scoping only; no rule removal | Checked against role layer before dispatch |

## Layered Inheritance Model

Rules inherit from broader to narrower scope. More specific layers win when a rule is explicitly overridden. Conflicts between layers at the same specificity level require explicit resolution — not silent last-write-wins.

```
Global rules (apply to all agents, all projects)
   └── Project rules (apply to all agents in this project)
         └── Role rules (apply to this agent type only)
               └── Task rules (apply to this specific invocation)
```

**Precedence:** Most specific wins. A role rule that says "use structured JSON for all output" overrides a project rule that says "output can be text or JSON." But a role rule cannot remove a global security constraint — it can only add further restriction.

**Conflict detection:** A conflict exists when two layers assert incompatible values for the same rule key. Detect conflicts at merge time:

```typescript
type RuleLayer = "global" | "project" | "role" | "task";

interface Rule {
  key: string;
  value: unknown;
  layer: RuleLayer;
  overrides?: string; // key of rule being explicitly overridden
}

interface ConflictReport {
  key: string;
  layers: RuleLayer[];
  values: unknown[];
  resolution: "most-specific-wins" | "explicit-override" | "unresolved";
}

const LAYER_PRECEDENCE: Record<RuleLayer, number> = {
  global: 0,
  project: 1,
  role: 2,
  task: 3,
};

function detectConflicts(rules: Rule[]): ConflictReport[] {
  const byKey = new Map<string, Rule[]>();
  for (const rule of rules) {
    const existing = byKey.get(rule.key) ?? [];
    byKey.set(rule.key, [...existing, rule]);
  }

  const conflicts: ConflictReport[] = [];
  for (const [key, layerRules] of byKey.entries()) {
    if (layerRules.length <= 1) continue;
    const hasExplicitOverride = layerRules.some(r => r.overrides === key);
    const values = layerRules.map(r => r.value);
    const allSame = values.every(v => JSON.stringify(v) === JSON.stringify(values[0]));
    if (!allSame) {
      conflicts.push({
        key,
        layers: layerRules.map(r => r.layer),
        values,
        resolution: hasExplicitOverride ? "explicit-override" : "most-specific-wins",
      });
    }
  }
  return conflicts;
}
```

## The CLAUDE.md Pattern

Claude Code uses layered markdown files to propagate shared instructions across all agent invocations without duplicating content into each prompt. This pattern is directly applicable to any agent system.

**Claude Code's hierarchy:**
- `~/.claude/CLAUDE.md` — global rules that apply to every project and every agent session
- `<project>/CLAUDE.md` — project-level rules that override or extend global rules for this codebase
- `<project>/.claude/rules/<topic>.md` — topic-specific rule files loaded based on context (e.g., `security.md`, `testing.md`)
- `<project>/.claude/agents/<name>.md` — role-specific instructions for individual agent types

**Why it works:** Each layer is a file, not a prompt injection. The system reads the files at invocation time, merges them in precedence order, and constructs the final instruction set. Agents never see raw CLAUDE.md files — they receive the merged result. Changes to any layer propagate automatically to all future invocations without touching agent code.

**Applying this pattern to any agent system:**

```
~/.agent-system/global-rules.md        # global
<project>/agent-rules.md               # project
<project>/agents/<role>/rules.md       # role
<task-payload>/task-constraints.md     # task (ephemeral)
```

```python
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

@dataclass(frozen=True)
class AgentRuleSet:
    global_rules: str
    project_rules: str
    role_rules: str
    task_constraints: str

def load_rule_set(
    global_path: Path,
    project_path: Path,
    role_path: Path,
    task_constraints: Optional[str] = None,
) -> AgentRuleSet:
    def read_safe(p: Path) -> str:
        return p.read_text(encoding="utf-8") if p.exists() else ""

    return AgentRuleSet(
        global_rules=read_safe(global_path),
        project_rules=read_safe(project_path),
        role_rules=read_safe(role_path),
        task_constraints=task_constraints or "",
    )

def build_system_prompt(rule_set: AgentRuleSet) -> str:
    sections = [
        ("Global Rules", rule_set.global_rules),
        ("Project Rules", rule_set.project_rules),
        ("Role Rules", rule_set.role_rules),
        ("Task Constraints", rule_set.task_constraints),
    ]
    return "\n\n".join(
        f"## {title}\n{content}"
        for title, content in sections
        if content.strip()
    )
```

## Override Resolution

When a narrower layer overrides a broader one, the override must be explicit and documented. Silent overrides — where a rule is simply replaced by a later value without declaring intent — are a leading cause of behavioral drift.

**Explicit override:** The rule declares what it is overriding and why.

```typescript
interface ExplicitOverride {
  key: string;
  value: unknown;
  layer: RuleLayer;
  overrides: string;       // key of the rule being superseded
  reason: string;          // why the override is necessary
  approvedBy?: string;     // optional: who authorized the deviation
}
```

**Implicit inheritance:** The rule adds to or refines the parent without replacing it. No documentation required — inheritance is the default.

**Merge strategies:**

| Strategy | Behavior | Use When |
|----------|----------|----------|
| Replace | Child value fully replaces parent value | Output format, model selection |
| Append | Child value is added to parent list | Allowed tools, output fields |
| Merge | Child and parent values are deep-merged | JSON config objects, flag sets |
| Restrict | Child narrows parent's allowable set | Security constraints, scope limits |

```typescript
type MergeStrategy = "replace" | "append" | "merge" | "restrict";

function applyMerge(
  parent: unknown,
  child: unknown,
  strategy: MergeStrategy
): unknown {
  switch (strategy) {
    case "replace":
      return child;
    case "append":
      if (Array.isArray(parent) && Array.isArray(child)) {
        return [...parent, ...child];
      }
      return child;
    case "merge":
      if (typeof parent === "object" && typeof child === "object"
          && parent !== null && child !== null) {
        return { ...parent, ...child };
      }
      return child;
    case "restrict":
      if (Array.isArray(parent) && Array.isArray(child)) {
        return parent.filter(v => (child as unknown[]).includes(v));
      }
      return child;
  }
}
```

## Consistency Enforcement

Shared rules are only effective if agents actually follow them. Enforcement requires runtime validation — checking agent outputs against the shared rule set after each invocation.

**Compliance scoring:** Each output is assessed against the full rule set. Rules are weighted by severity (critical, high, medium, low). A compliance score below threshold triggers a retry or escalation.

```typescript
interface ComplianceCheck {
  ruleKey: string;
  severity: "critical" | "high" | "medium" | "low";
  passed: boolean;
  detail?: string;
}

interface ComplianceReport {
  agentId: string;
  cycle: number;
  score: number;        // 0.0 to 1.0
  checks: ComplianceCheck[];
  passed: boolean;
  driftDetected: boolean;
}

const SEVERITY_WEIGHTS: Record<ComplianceCheck["severity"], number> = {
  critical: 1.0,
  high: 0.5,
  medium: 0.2,
  low: 0.05,
};

function scoreCompliance(checks: ComplianceCheck[]): number {
  const totalWeight = checks.reduce((sum, c) => sum + SEVERITY_WEIGHTS[c.severity], 0);
  const passedWeight = checks
    .filter(c => c.passed)
    .reduce((sum, c) => sum + SEVERITY_WEIGHTS[c.severity], 0);
  return totalWeight === 0 ? 1.0 : passedWeight / totalWeight;
}
```

**Drift detection:** Compare compliance scores across cycles for the same agent type. A downward trend signals rule drift — the agent's behavior is drifting away from the shared baseline. Trigger a rule refresh when drift exceeds threshold.

**Automated enforcement hooks:** Attach a post-output hook that runs compliance checks before the output is consumed downstream. Reject non-compliant outputs immediately with a structured error, rather than propagating bad output through the pipeline.

## Value Propagation in Parallel Agents

When N agents run in parallel, injecting shared context naively multiplies prompt token cost by N. Template-based injection separates the shared content from the injection mechanism, enabling efficient propagation.

**Template injection:** Shared rules are loaded once, then injected into each agent's prompt via a template slot — not repeated verbatim for each agent.

```typescript
interface AgentPromptTemplate {
  systemPromptTemplate: string;  // contains {{shared_rules}}, {{role_rules}}, {{task}}
  sharedRulesRef: string;        // key into a shared context store — not the full text
  roleRulesRef: string;
}

interface SharedContextStore {
  get(ref: string): string;
  version(): string;
}

function buildParallelPrompts(
  template: AgentPromptTemplate,
  tasks: string[],
  store: SharedContextStore
): string[] {
  const sharedRules = store.get(template.sharedRulesRef);
  const roleRules = store.get(template.roleRulesRef);

  return tasks.map(task =>
    template.systemPromptTemplate
      .replace("{{shared_rules}}", sharedRules)
      .replace("{{role_rules}}", roleRules)
      .replace("{{task}}", task)
  );
}
```

**Context inheritance chains:** Rather than flattening all rules into a single prompt, pass a context chain — each layer is a separate field. The agent's system prompt explains the inheritance order. This preserves layer identity for later auditing.

```python
from dataclasses import dataclass
from typing import List

@dataclass(frozen=True)
class ContextChain:
    layers: tuple  # ordered from broadest to narrowest
    version: str

    def to_prompt_block(self) -> str:
        parts = []
        for i, layer in enumerate(self.layers):
            label = ["Global", "Project", "Role", "Task"][min(i, 3)]
            parts.append(f"### {label} Rules\n{layer}")
        return "\n\n".join(parts)
```

**Shared context versioning:** Include a `contextVersion` in each agent's task payload. If the shared rules change mid-cycle, agents on the old version are flagged for re-evaluation before their outputs are merged.

## Conflict Detection and Resolution

Conflicts arise when two rule layers assert incompatible constraints. Unresolved conflicts produce agents that cannot satisfy all rules simultaneously — leading to inconsistent outputs or silent rule violations.

**Detection triggers:**
- Two layers define the same rule key with different values and no explicit override
- A role rule removes a restriction that a global rule mandates
- Task constraints request behavior prohibited by project rules

**Priority-based resolution:**

```typescript
function resolveConflict(conflict: ConflictReport): Rule {
  if (conflict.resolution === "explicit-override") {
    // Trust the explicit override — it was intentional
    const sorted = conflict.layers
      .map(layer => ({ layer, precedence: LAYER_PRECEDENCE[layer] }))
      .sort((a, b) => b.precedence - a.precedence);
    const winningLayer = sorted[0].layer;
    const winningValue = conflict.values[conflict.layers.indexOf(winningLayer)];
    return { key: conflict.key, value: winningValue, layer: winningLayer };
  }
  // most-specific-wins: take highest precedence layer
  const maxPrecedence = Math.max(...conflict.layers.map(l => LAYER_PRECEDENCE[l]));
  const winningLayer = conflict.layers.find(l => LAYER_PRECEDENCE[l] === maxPrecedence)!;
  const winningValue = conflict.values[conflict.layers.indexOf(winningLayer)];
  return { key: conflict.key, value: winningValue, layer: winningLayer };
}
```

**Human escalation triggers:** Some conflicts cannot be resolved by precedence alone. Escalate to human review when:
- A task-level override contradicts a global security rule
- Two role-level rules in a peer system contradict each other with no common parent
- A conflict involves a `critical` severity rule
- The same conflict recurs across more than 3 cycles (systemic mismatch, not an edge case)

Log all escalations with full conflict context so the human reviewer can update the rule hierarchy permanently rather than patching each invocation.

## Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Rule Sprawl** | Hundreds of small rules distributed across many files with overlapping scope — agents cannot determine which applies | Consolidate into a canonical hierarchy; enforce a maximum of 4 layers |
| **Undocumented Overrides** | Role rules silently replace global rules with no `overrides` declaration — drift is invisible | Require explicit `overrides` field on any rule that supersedes a parent |
| **Conflicting Sources of Truth** | Global rules in one file, project rules in a database, role rules inline in prompts — no single merge path | Standardize all rule layers as versioned markdown files in a known directory structure |
| **Over-Constraining Agents** | Every rule from every layer injected into every prompt regardless of relevance — context bloat | Use role-based context slicing; each agent receives only rules relevant to its function |
| **Implicit Assumptions** | Agents behave correctly in testing because the developer's environment has unwritten rules — fails in production | Document every behavioral assumption as an explicit rule in the appropriate layer |
| **Static Shared Context** | Shared rules are loaded once at system startup and never refreshed — stale rules accumulate | Version shared context; detect and propagate updates within a cycle |
| **Rule Removal by Narrowing** | A task-level constraint removes a global rule rather than restricting it — security guarantees are silently dropped | Validate that narrower layers can only restrict, not remove, rules from broader layers |

## Cross-References

- `agent-orchestration-patterns` — layered context inheritance, shared context and rules pattern, context versioning; the orchestration primitives that consume shared values
- `agent-memory-patterns` — how shared rule versions are persisted and retrieved across cycles; shared memory stores for rule state
- `agent-self-evaluation-patterns` — how agents self-assess compliance with shared rules; confidence scoring against rule sets; drift reporting
