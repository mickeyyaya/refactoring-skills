---
name: agent-self-evaluation-patterns
description: Use when designing or reviewing AI agents that must assess their own output quality — covers confidence scoring and calibration, chain-of-thought reflection, LLM-as-judge, hallucination self-detection, output quality verification, eval-driven development, and self-evaluation anti-patterns with examples in TypeScript and Python
---

# Agent Self-Evaluation Patterns

## Overview

AI agents that cannot evaluate their own output quality are unreliable in production. A model that confidently produces wrong answers, fabricates citations, or never flags uncertainty becomes a liability rather than an asset. Self-evaluation patterns give agents structured mechanisms to detect errors, express calibrated uncertainty, and improve output quality before results reach users.

**When to use:** Designing agents that produce factual claims, code, analysis, or structured data; reviewing agent pipelines for hallucination risk; building eval suites for AI-generated content; any system where incorrect LLM output has meaningful downstream consequences.

## Quick Reference

| Pattern | Core Problem | Key Technique | Failure Mode |
|---------|-------------|---------------|--------------|
| Confidence Scoring | Agent returns wrong answers with false certainty | Logprob analysis, self-consistency sampling | Overconfident scoring — high score on hallucinated output |
| Chain-of-Thought Reflection | Errors baked into first draft go unchallenged | Generate → critique → revise cycle | Rubber-stamp reflection — critique that validates the original uncritically |
| LLM-as-Judge | Model cannot objectively evaluate its own output | Separate judge call with scoring rubric | Same model judging itself — no independence, shared biases |
| Hallucination Self-Detection | Claims unverifiable against source material | Source grounding checks, API existence verification | Reflection loop amplifies fabricated details instead of catching them |
| Output Quality Verification | Schema or structural errors in generated output | Assertion-based checking, schema validation | Checking format only — passes schema but semantically wrong |
| Eval-Driven Development | No objective measure of agent improvement | Define graders before implementation, regression gates | Graders written after the fact, shaped to pass existing output |

## Confidence Scoring

Confidence scoring gives an agent a numerical signal for how certain it is about a given output. Well-calibrated agents express genuine uncertainty rather than projecting false confidence.

**Techniques:**

- **Logprob analysis** — for models exposing token log-probabilities, low average logprob on key tokens signals uncertain output. A logprob below -2.0 on a named entity suggests hallucination risk.
- **Self-consistency sampling** — generate N answers at temperature > 0; high agreement across samples signals genuine confidence, divergence signals uncertainty.
- **Explicit uncertainty elicitation** — prompt the model to rate its own confidence on a 0–1 scale, then calibrate by checking historical accuracy at each score band.
- **Abstain threshold** — define a minimum confidence threshold below which the agent returns "I don't know" instead of a low-quality guess.

**Calibration principle (Rewarding Doubt, OpenAI 2025):** Models trained to express genuine uncertainty outperform overconfident models on downstream tasks because downstream consumers can route uncertain outputs to fallback paths rather than acting on bad information.

```typescript
import { OpenAI } from "openai";

const openai = new OpenAI();

interface ConfidenceResult {
  answer: string;
  confidence: number;   // 0.0–1.0
  abstained: boolean;
  reasoning: string;
}

const CONFIDENCE_SYSTEM_PROMPT = `You are a factual assistant with calibrated uncertainty.
For each question, provide:
1. Your best answer
2. A confidence score from 0.0 to 1.0 based on how certain you are
3. Whether you are abstaining due to insufficient information
4. A brief reasoning for your confidence level

Rules:
- Score 0.9+ only when you are highly certain the answer is verifiable fact
- Score below 0.5 when you are guessing or extrapolating
- Set abstained=true when confidence < 0.4 — do not guess
- Respond ONLY with JSON: {"answer":string,"confidence":number,"abstained":boolean,"reasoning":string}`;

async function confidenceQuery(question: string): Promise<ConfidenceResult> {
  const response = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [
      { role: "system", content: CONFIDENCE_SYSTEM_PROMPT },
      { role: "user", content: question },
    ],
    response_format: { type: "json_object" },
    temperature: 0,
  });

  const raw = JSON.parse(response.choices[0].message.content ?? "{}");
  const result = raw as ConfidenceResult;
  if (result.abstained || result.confidence < 0.4) {
    return { ...result, answer: "I don't have sufficient information to answer reliably." };
  }
  return result;
}

// Self-consistency sampling: generate N answers, pick consensus
async function selfConsistencyQuery(question: string, samples = 5): Promise<{ answer: string; consistency: number }> {
  const responses = await Promise.all(
    Array.from({ length: samples }, () =>
      openai.chat.completions.create({
        model: "gpt-4o",
        messages: [{ role: "user", content: question }],
        temperature: 0.7,
        max_tokens: 100,
      })
    )
  );

  const answers = responses.map(r => r.choices[0].message.content?.trim() ?? "");
  const frequency = new Map<string, number>();
  for (const a of answers) frequency.set(a, (frequency.get(a) ?? 0) + 1);
  const [topAnswer, topCount] = [...frequency.entries()].sort((a, b) => b[1] - a[1])[0];
  return { answer: topAnswer, consistency: topCount / samples };
}
```

## Chain-of-Thought Reflection

Chain-of-thought (CoT) reflection is a generate → critique → revise cycle where the agent produces a first draft, explicitly critiques its own reasoning, and issues a revised answer. This separates generation from evaluation, reducing errors that survive unchallenged in single-pass output.

**Cycle stages:**

1. **Generate** — produce an initial answer with full reasoning visible
2. **Critique** — identify logical gaps, unsupported claims, missing edge cases, and factual assumptions
3. **Revise** — issue a corrected answer that addresses the critique

**Reflection depth limits:** Cap the critique-revise loop at 2–3 iterations. Beyond that, the model tends to oscillate or introduce new errors. Track whether each revision actually changed the answer — if two consecutive revisions are identical, stop early.

**Structured self-review prompts:** Use XML tags or explicit section headers to separate reasoning from output, preventing the model from conflating thinking with its final answer.

```typescript
interface ReflectionResult {
  initialAnswer: string;
  critique: string;
  revisedAnswer: string;
  iterations: number;
  changed: boolean;
}

const REFLECT_PROMPT = `Review your previous answer critically.
Identify:
1. Logical errors or gaps in reasoning
2. Unsupported factual claims
3. Missing edge cases or counterexamples
4. Ambiguities that need clarification

Then provide a revised answer that fixes the issues found.
Format:
<critique>[your critical analysis]</critique>
<revised>[corrected answer]</revised>`;

async function reflectAndRevise(question: string, maxIterations = 2): Promise<ReflectionResult> {
  const messages: OpenAI.Chat.ChatCompletionMessageParam[] = [{ role: "user", content: question }];
  const initial = await openai.chat.completions.create({ model: "gpt-4o", messages, temperature: 0 });
  let currentAnswer = initial.choices[0].message.content ?? "";
  messages.push({ role: "assistant", content: currentAnswer });

  let critique = "";
  let iterations = 0;

  for (let i = 0; i < maxIterations; i++) {
    messages.push({ role: "user", content: REFLECT_PROMPT });
    const reflection = await openai.chat.completions.create({ model: "gpt-4o", messages, temperature: 0 });
    const reflectionText = reflection.choices[0].message.content ?? "";

    const critiqueMatch = reflectionText.match(/<critique>([\s\S]*?)<\/critique>/);
    const revisedMatch = reflectionText.match(/<revised>([\s\S]*?)<\/revised>/);
    critique = critiqueMatch?.[1]?.trim() ?? "";
    const revised = revisedMatch?.[1]?.trim() ?? currentAnswer;

    if (revised === currentAnswer) break;   // no change — stop early
    currentAnswer = revised;
    messages.push({ role: "assistant", content: reflectionText });
    iterations = i + 1;
  }

  return { initialAnswer: initial.choices[0].message.content ?? "", critique, revisedAnswer: currentAnswer, iterations, changed: iterations > 0 };
}
```

## LLM-as-Judge

LLM-as-judge uses a separate model call — ideally a different model or a fresh instance with no prior context — to evaluate output quality against a defined rubric. This provides independence: the judge has not seen the generation process and cannot rationalize away errors.

**Judge design principles:**

- Use a stronger or different model as judge when possible to avoid shared biases
- Provide an explicit scoring rubric with defined criteria (accuracy, completeness, relevance, safety)
- Request a numeric score and a written justification — scores without reasoning are hard to debug
- Normalize judge outputs: instruct the judge to use a fixed scale (e.g., 1–5) with anchored descriptions

**Grading rubrics:** Define rubric criteria before writing the judge prompt. Each criterion should have a clear definition of what a score of 1, 3, and 5 looks like. Vague rubrics produce inconsistent scores.

```typescript
interface JudgeScore {
  accuracy: number;       // 1–5: factual correctness
  completeness: number;   // 1–5: all aspects of question addressed
  relevance: number;      // 1–5: answer stays on topic
  overall: number;        // 1–5: holistic quality
  justification: string;
  passed: boolean;        // overall >= 3.5
}

const JUDGE_SYSTEM_PROMPT = `You are an objective answer quality evaluator.
Score the provided answer on four criteria, each from 1 to 5:

Accuracy (1=multiple factual errors, 3=minor inaccuracies, 5=fully correct)
Completeness (1=major gaps, 3=partially addressed, 5=thorough)
Relevance (1=off-topic, 3=partially relevant, 5=directly addresses the question)
Overall (1=unusable, 3=acceptable, 5=excellent)

Respond ONLY with JSON:
{"accuracy":number,"completeness":number,"relevance":number,"overall":number,"justification":string}`;

async function judgeAnswer(question: string, answer: string): Promise<JudgeScore> {
  const response = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [
      { role: "system", content: JUDGE_SYSTEM_PROMPT },
      { role: "user", content: `Question: ${question}\n\nAnswer to evaluate:\n${answer}` },
    ],
    response_format: { type: "json_object" },
    temperature: 0,
  });

  const raw = JSON.parse(response.choices[0].message.content ?? "{}") as Omit<JudgeScore, "passed">;
  return { ...raw, passed: raw.overall >= 3.5 };
}
```

```python
import json
from openai import OpenAI

client = OpenAI()

def judge_answer(question: str, answer: str, pass_threshold: float = 3.5) -> dict:
    """Evaluate answer quality using LLM-as-judge with rubric scoring."""
    response = client.chat.completions.create(
        model="gpt-4o",
        messages=[
            {"role": "system", "content": (
                "Score this answer on accuracy, completeness, and relevance (1–5 each). "
                "Return JSON: {\"accuracy\":int,\"completeness\":int,\"relevance\":int,"
                "\"overall\":float,\"justification\":string}"
            )},
            {"role": "user", "content": f"Question: {question}\n\nAnswer:\n{answer}"},
        ],
        response_format={"type": "json_object"},
        temperature=0,
    )
    result = json.loads(response.choices[0].message.content or "{}")
    result["passed"] = result.get("overall", 0) >= pass_threshold
    return result
```

Cross-reference: `review-accuracy-calibration` — calibrating judge scores against human ratings.

## Hallucination Self-Detection

Hallucination self-detection is the process of verifying claims in agent output against ground truth — retrieved documents, API responses, or schema definitions — before returning the output to the caller.

**Verification strategies:**

- **Source grounding check** — for each factual claim, verify it appears verbatim or paraphrased in the retrieved context; flag claims with no source match
- **API existence verification** — when agents generate code, verify that referenced functions, methods, and APIs exist in installed packages or known schemas
- **Citation verification** — when citations are generated, confirm URL/source exists and the cited excerpt is present in the source text
- **Fact cross-reference** — for high-stakes numeric claims (dates, statistics), cross-reference against a second retrieval or known data source

```typescript
interface ClaimVerification {
  claim: string;
  verified: boolean;
  sourceExcerpt: string | null;
  confidence: "supported" | "partial" | "unsupported";
}

async function verifyClaims(
  answer: string,
  sourceContext: string
): Promise<ClaimVerification[]> {
  const response = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [
      {
        role: "system",
        content: `You are a fact-checker. Given an answer and source context, identify each factual claim in the answer.
For each claim, check if it is directly supported, partially supported, or unsupported by the source context.
Respond with JSON array: [{"claim":string,"verified":boolean,"sourceExcerpt":string|null,"confidence":"supported"|"partial"|"unsupported"}]`,
      },
      {
        role: "user",
        content: `Answer:\n${answer}\n\nSource Context:\n${sourceContext}`,
      },
    ],
    response_format: { type: "json_object" },
    temperature: 0,
  });

  const raw = JSON.parse(response.choices[0].message.content ?? '{"items":[]}');
  return Array.isArray(raw) ? raw : (raw.items ?? []);
}

// API existence verification for generated code
function verifyApiExists(modulePath: string, symbolName: string): boolean {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require(modulePath);
    return symbolName in mod || typeof mod[symbolName] !== "undefined";
  } catch {
    return false;
  }
}
```

## Output Quality Verification

Output quality verification applies deterministic checks after LLM generation. Schema validation and assertion-based checking catch structural errors that self-critique may miss because it uses the same model that made the error.

**Verification layers:**

1. **Schema validation** — parse and validate output against a strict schema (Zod, Pydantic) before use
2. **Assertion-based checking** — define invariants the output must satisfy (non-empty fields, valid ranges, required relationships)
3. **Before/after comparison** — for transformation tasks, verify the output preserves required properties of the input
4. **Test-driven output** — define example inputs and expected outputs before building the agent; run these as regression tests

```typescript
import { z } from "zod";

const AgentOutputSchema = z.object({
  summary: z.string().min(10).max(500),
  keyPoints: z.array(z.string().min(5)).min(1).max(10),
  sentiment: z.enum(["positive", "negative", "neutral"]),
  confidence: z.number().min(0).max(1),
  sources: z.array(z.string().url()).optional(),
});

type AgentOutput = z.infer<typeof AgentOutputSchema>;

function verifyAgentOutput(raw: unknown): { valid: boolean; data?: AgentOutput; errors?: string[] } {
  const result = AgentOutputSchema.safeParse(raw);
  if (result.success) return { valid: true, data: result.data };
  return { valid: false, errors: result.error.issues.map(i => `${i.path.join(".")}: ${i.message}`) };
}

// Assertion-based invariant checks beyond schema
function assertOutputInvariants(output: AgentOutput, inputLength: number): string[] {
  const violations: string[] = [];
  if (output.summary.length > inputLength * 0.5) violations.push("Summary exceeds 50% of input length — likely not summarized");
  if (output.confidence > 0.9 && output.sources === undefined) violations.push("High confidence claimed without sources");
  if (output.keyPoints.length === 1 && inputLength > 500) violations.push("Only one key point extracted from long input — possible truncation");
  return violations;
}
```

## Eval-Driven Development

Eval-driven development treats eval graders as the specification: define how success will be measured before writing any agent logic. This prevents the common failure where graders are written after the fact and shaped to pass existing output.

**Workflow:**

1. **Define graders** — write executable eval tests (bash, Python, TS) that check output properties
2. **Baseline** — run graders against a naive implementation to establish a baseline score
3. **Implement** — build the agent against the graders, not against intuition
4. **Gate on regression** — block merges that lower eval scores; track scores as metrics over time
5. **Adversarial examples** — include edge cases and known failure modes in the eval suite

**Automated eval suite patterns:**

- **String match graders** — exact or regex match for deterministic outputs
- **Schema graders** — validate output parses against a schema
- **LLM graders** — use a judge model to score open-ended quality
- **Behavioral graders** — run the agent end-to-end and assert on side effects

```python
import subprocess
import json
from dataclasses import dataclass
from typing import Callable

@dataclass
class EvalCase:
    name: str
    input: dict
    graders: list[Callable[[dict], bool]]
    weight: float = 1.0

def run_eval_suite(agent_fn: Callable, cases: list[EvalCase]) -> dict:
    """Run an eval suite and return pass rate and per-case results."""
    results = []
    for case in cases:
        try:
            output = agent_fn(case.input)
            passed = all(grader(output) for grader in case.graders)
        except Exception as exc:
            passed = False
            output = {"error": str(exc)}
        results.append({"name": case.name, "passed": passed, "output": output})

    pass_count = sum(1 for r in results if r["passed"])
    return {
        "total": len(cases),
        "passed": pass_count,
        "pass_rate": pass_count / len(cases) if cases else 0.0,
        "results": results,
    }

# Example graders
def grader_non_empty_answer(output: dict) -> bool:
    return bool(output.get("answer", "").strip())

def grader_confidence_in_range(output: dict) -> bool:
    c = output.get("confidence", -1)
    return isinstance(c, (int, float)) and 0.0 <= c <= 1.0

def grader_no_hallucination_markers(output: dict) -> bool:
    hallucination_phrases = ["as of my knowledge cutoff", "I believe", "I think", "may have"]
    answer = output.get("answer", "").lower()
    return not any(phrase.lower() in answer for phrase in hallucination_phrases)
```

Cross-reference: `ai-ml-integration-patterns` — structured output with schema validation; hallucination mitigation patterns.

## Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Overconfident self-assessment** | Agent assigns confidence 0.9+ to hallucinated answers — calibration never tested against ground truth | Run calibration eval: compare confidence scores to actual accuracy rates; penalize overconfident incorrect answers in fine-tuning |
| **Rubber-stamp self-review** | Reflection step echoes the original answer with minor rephrasing — no genuine critique | Require the critique to identify at least one specific concern; reject reflections that do not name a concrete issue |
| **Hallucination amplification** | Reflection loop asks the model to elaborate on a hallucinated fact, generating more detail around the error | Ground reflection against source context; the critique step must reference documents, not generate new claims |
| **Same-model judge** | Using the same model that generated the output to judge it — shared biases make the judge lenient | Use a separate model, a stronger model, or a structured rubric with forced failure criteria |
| **Graders written after output** | Eval graders designed to pass existing output rather than test the specification | Write graders from the task spec before any implementation; treat failing graders as bugs in the agent |
| **Ignoring abstention** | Agent never returns "I don't know" — low-confidence guesses returned as facts | Define and enforce an abstain threshold; log abstention rate as a quality metric |
| **Single-pass verification** | Schema validation passes but semantic correctness is never checked | Layer schema checks with assertion-based invariant checks and optional LLM-judge scoring |

## Cross-References

- `ai-ml-integration-patterns` — RAG pipeline design, hallucination mitigation, structured output validation, and LLM error handling patterns
- `ai-generated-code-review` — reviewing and verifying LLM-generated code for correctness, security, and style
- `review-accuracy-calibration` — calibrating reviewer and judge scores against human ground truth; inter-rater reliability measurement
