---
name: ai-ml-integration-patterns
description: Use when designing or reviewing AI/ML integration code — covers RAG pipeline design, prompt engineering, structured output with schema validation, tool use/function calling, LLM error handling, token budget management, hallucination mitigation, and AI/ML anti-patterns with examples in TypeScript and Python
---

# AI/ML Integration Patterns

## Overview

Integrating LLMs into production systems introduces failure modes unique to probabilistic outputs: hallucinated facts, unbounded token costs, prompt injection attacks, and unvalidated structured responses. Use this guide when designing, building, or reviewing code that calls LLM APIs, builds RAG pipelines, or orchestrates AI agents.

**When to use:** Reviewing code that calls OpenAI, Anthropic, or other LLM APIs; evaluating RAG pipeline design; auditing prompt construction; any system that relies on LLM-generated structured output or tool execution loops.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| RAG Pipeline | Ground LLM answers in retrieved documents | Retrieval without relevance filtering; missing context window budget |
| Prompt Engineering | Structured prompts for reliable, reproducible outputs | Hardcoded prompts scattered in code; no version control |
| Structured Output + Schema | Validate LLM JSON against a schema before using it | Trusting raw LLM output as typed data |
| Tool Use / Function Calling | LLM selects and invokes registered tools; app executes | Executing tool calls without validating arguments |
| LLM Error Handling | Retry rate limits, fall back on model failures, timeout on hangs | No retry on 429; no timeout on streaming calls |
| Token Budget Management | Count, chunk, and truncate to stay within context limits | Unlimited context assembly; no chunk size cap |
| Hallucination Mitigation | Source citation, confidence scoring, guardrails | LLM answers used directly with no grounding check |
| Anti-Patterns | Common misuse patterns that cause prod failures | Prompt injection via user input; no output validation |

---

## Patterns in Detail

### 1. RAG (Retrieval-Augmented Generation) Pipeline

RAG grounds LLM responses in real data by retrieving relevant documents at query time and injecting them into the context window.

**Pipeline stages:**
1. **Embedding** — convert documents and queries to dense vectors
2. **Vector store** — index and persist embeddings for ANN search
3. **Retrieval** — query vector store with top-k similarity
4. **Reranking** (optional) — re-score candidates with a cross-encoder
5. **Context window management** — pack retrieved chunks within token budget
6. **Generation** — LLM answers using grounded context

**Red Flags:**
- Retrieval without relevance threshold — irrelevant chunks injected into context
- No deduplication of retrieved chunks — redundant tokens waste context budget
- Embedding model mismatch between indexing and query time
- Context window assembly ignores token count — exceeds model limit at runtime

**TypeScript:**
```typescript
import { OpenAI } from "openai";
import { encode } from "gpt-tokenizer";

const openai = new OpenAI();

interface Chunk { id: string; text: string; score: number; source: string; }

async function buildRagContext(
  query: string,
  retrievedChunks: Chunk[],
  maxContextTokens = 3000
): Promise<{ context: string; sources: string[] }> {
  // Filter by relevance threshold before packing
  const relevant = retrievedChunks.filter(c => c.score >= 0.75);

  const packed: string[] = [];
  const sources: string[] = [];
  let tokenCount = 0;

  for (const chunk of relevant) {
    const chunkTokens = encode(chunk.text).length;
    if (tokenCount + chunkTokens > maxContextTokens) break;
    packed.push(`[Source: ${chunk.source}]\n${chunk.text}`);
    sources.push(chunk.source);
    tokenCount += chunkTokens;
  }

  return { context: packed.join("\n\n---\n\n"), sources };
}

async function ragQuery(query: string, chunks: Chunk[]): Promise<string> {
  const { context, sources } = await buildRagContext(query, chunks);

  const response = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [
      {
        role: "system",
        content: "Answer using ONLY the provided context. If the answer is not in the context, say 'I don't have enough information.'"
      },
      {
        role: "user",
        content: `Context:\n${context}\n\nQuestion: ${query}`
      }
    ],
    temperature: 0,
  });

  const answer = response.choices[0].message.content ?? "";
  return `${answer}\n\nSources: ${[...new Set(sources)].join(", ")}`;
}
```

**Python:**
```python
import tiktoken
from openai import OpenAI
from dataclasses import dataclass

client = OpenAI()
enc = tiktoken.encoding_for_model("gpt-4o")

@dataclass
class Chunk:
    id: str
    text: str
    score: float
    source: str

def build_rag_context(
    chunks: list[Chunk],
    max_tokens: int = 3000,
    min_score: float = 0.75
) -> tuple[str, list[str]]:
    relevant = [c for c in chunks if c.score >= min_score]
    packed, sources, token_count = [], [], 0
    for chunk in relevant:
        tokens = len(enc.encode(chunk.text))
        if token_count + tokens > max_tokens:
            break
        packed.append(f"[Source: {chunk.source}]\n{chunk.text}")
        sources.append(chunk.source)
        token_count += tokens
    return "\n\n---\n\n".join(packed), list(dict.fromkeys(sources))

def rag_query(query: str, chunks: list[Chunk]) -> str:
    context, sources = build_rag_context(chunks)
    response = client.chat.completions.create(
        model="gpt-4o",
        messages=[
            {"role": "system", "content": "Answer using ONLY the provided context."},
            {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {query}"}
        ],
        temperature=0,
    )
    answer = response.choices[0].message.content or ""
    return f"{answer}\n\nSources: {', '.join(sources)}"
```

Cross-reference: `data-pipeline-patterns` — chunking and embedding pipeline stages.

---

### 2. Prompt Engineering Patterns

Reliable LLM outputs require structured, versioned prompts — not ad-hoc string concatenation.

**Patterns:**
- **System prompt** — define role, constraints, and output format once
- **Few-shot examples** — show 2-5 input/output pairs to anchor behavior
- **Chain-of-thought** — instruct the model to reason before answering ("Think step by step")
- **Structured output instruction** — embed JSON schema or format spec in the prompt
- **Prompt versioning** — store prompts in config or database with version identifiers

**Red Flags:**
- Prompts built with string concatenation scattered across the codebase
- User input injected directly into system prompts (prompt injection risk)
- No few-shot examples for complex classification or extraction tasks
- Chain-of-thought reasoning mixed with final output — parse errors at runtime

**TypeScript:**
```typescript
// BEFORE — ad-hoc, scattered, unversioned
const prompt = `You are a helpful assistant. User said: ${userMessage}`;

// AFTER — versioned prompt template with separation of concerns
interface PromptTemplate {
  version: string;
  systemPrompt: string;
  fewShotExamples: Array<{ input: string; output: string }>;
}

const SENTIMENT_PROMPT_V2: PromptTemplate = {
  version: "2.0",
  systemPrompt: [
    "You are a sentiment analysis engine.",
    "Classify the sentiment of the input as: positive, negative, or neutral.",
    "Respond ONLY with valid JSON: {\"sentiment\": \"<label>\", \"confidence\": <0.0-1.0>}",
    "Do not include any explanation or additional text."
  ].join("\n"),
  fewShotExamples: [
    { input: "I love this product!", output: '{"sentiment":"positive","confidence":0.98}' },
    { input: "This is terrible.", output: '{"sentiment":"negative","confidence":0.95}' },
    { input: "It works.", output: '{"sentiment":"neutral","confidence":0.80}' },
  ],
};

function buildMessages(template: PromptTemplate, userInput: string) {
  return [
    { role: "system" as const, content: template.systemPrompt },
    // few-shot examples as alternating user/assistant turns
    ...template.fewShotExamples.flatMap(ex => [
      { role: "user" as const, content: ex.input },
      { role: "assistant" as const, content: ex.output },
    ]),
    { role: "user" as const, content: userInput },
  ];
}
```

**Python — chain-of-thought pattern:**
```python
COT_SYSTEM_PROMPT = """You are a math reasoning assistant.
Think through each problem step by step, then provide your final answer.

Format your response as:
<reasoning>
[your step-by-step thinking]
</reasoning>
<answer>
[final answer only]
</answer>"""

import re

def extract_cot_answer(response: str) -> tuple[str, str]:
    """Extract reasoning and final answer from chain-of-thought response."""
    reasoning_match = re.search(r"<reasoning>(.*?)</reasoning>", response, re.DOTALL)
    answer_match = re.search(r"<answer>(.*?)</answer>", response, re.DOTALL)
    reasoning = reasoning_match.group(1).strip() if reasoning_match else ""
    answer = answer_match.group(1).strip() if answer_match else response
    return reasoning, answer
```

---

### 3. Structured Output with Schema Validation

LLMs do not guarantee valid JSON or correct field types. Always validate structured output against a schema before using it in application logic.

**Red Flags:**
- `JSON.parse(llmResponse)` with no schema validation — runtime crashes on malformed output
- Optional fields accessed without null checks — implicit trust in LLM output shape
- No retry on parse failure — single bad response causes permanent failure
- Schema defined only in the prompt, not enforced in code

**TypeScript (Zod):**
```typescript
import { z } from "zod";
import { OpenAI } from "openai";

const openai = new OpenAI();

const ProductExtractionSchema = z.object({
  name: z.string().min(1),
  price: z.number().positive(),
  currency: z.enum(["USD", "EUR", "GBP"]),
  inStock: z.boolean(),
  tags: z.array(z.string()).default([]),
});

type ProductExtraction = z.infer<typeof ProductExtractionSchema>;

async function extractProduct(text: string): Promise<ProductExtraction> {
  const MAX_ATTEMPTS = 3;

  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    const response = await openai.chat.completions.create({
      model: "gpt-4o",
      messages: [
        {
          role: "system",
          content: `Extract product information as JSON with fields:
            name (string), price (number), currency ("USD"|"EUR"|"GBP"),
            inStock (boolean), tags (string array).
            Return ONLY valid JSON, no markdown.`
        },
        { role: "user", content: text }
      ],
      response_format: { type: "json_object" },
    });

    const raw = response.choices[0].message.content ?? "{}";
    const parsed = ProductExtractionSchema.safeParse(JSON.parse(raw));

    if (parsed.success) return parsed.data;
    if (attempt === MAX_ATTEMPTS) {
      throw new Error(`Schema validation failed after ${MAX_ATTEMPTS} attempts: ${parsed.error.message}`);
    }
  }
  throw new Error("unreachable");
}
```

**Python (Pydantic):**
```python
from pydantic import BaseModel, Field, ValidationError
from openai import OpenAI
import json

client = OpenAI()

class ProductExtraction(BaseModel):
    name: str = Field(min_length=1)
    price: float = Field(gt=0)
    currency: str = Field(pattern="^(USD|EUR|GBP)$")
    in_stock: bool
    tags: list[str] = []

def extract_product(text: str, max_attempts: int = 3) -> ProductExtraction:
    for attempt in range(1, max_attempts + 1):
        response = client.chat.completions.create(
            model="gpt-4o",
            response_format={"type": "json_object"},
            messages=[
                {"role": "system", "content": "Extract product info as JSON: name, price, currency, in_stock, tags."},
                {"role": "user", "content": text},
            ],
        )
        raw = response.choices[0].message.content or "{}"
        try:
            return ProductExtraction.model_validate(json.loads(raw))
        except (ValidationError, json.JSONDecodeError) as e:
            if attempt == max_attempts:
                raise ValueError(f"Schema validation failed after {max_attempts} attempts: {e}") from e
    raise RuntimeError("unreachable")
```

Cross-reference: `data-validation-schema-patterns` — Zod and Pydantic schema patterns in depth.

---

### 4. Tool Use / Function Calling Patterns

LLMs can select and invoke tools (functions) to act on the world. The application owns execution — the LLM only decides which tool to call and with what arguments.

**Execution loop:**
1. Send messages + tool definitions to LLM
2. If response includes tool calls, validate arguments against schema
3. Execute tools and append results as `tool` role messages
4. Continue loop until LLM emits a non-tool response

**Red Flags:**
- Executing tool calls without validating arguments — LLM can hallucinate invalid inputs
- No maximum iteration cap on the tool loop — infinite loops on confused models
- Tool execution errors not fed back to the LLM — model retries blindly
- Destructive tools (delete, send email) with no confirmation step

**TypeScript:**
```typescript
import { OpenAI } from "openai";
import { z } from "zod";

const openai = new OpenAI();

// Tool argument schemas for validation
const GetWeatherArgs = z.object({ location: z.string(), unit: z.enum(["celsius", "fahrenheit"]) });
const SearchArgs = z.object({ query: z.string().min(1), maxResults: z.number().int().min(1).max(20).default(5) });

const TOOL_DEFINITIONS = [
  {
    type: "function" as const,
    function: {
      name: "get_weather",
      description: "Get current weather for a location",
      parameters: {
        type: "object",
        properties: {
          location: { type: "string", description: "City and country" },
          unit: { type: "string", enum: ["celsius", "fahrenheit"] },
        },
        required: ["location", "unit"],
      },
    },
  },
];

async function executeTool(name: string, rawArgs: unknown): Promise<string> {
  if (name === "get_weather") {
    const args = GetWeatherArgs.parse(rawArgs);  // validate before execution
    // actual implementation
    return JSON.stringify({ temperature: 22, condition: "sunny", location: args.location });
  }
  throw new Error(`Unknown tool: ${name}`);
}

async function runAgentLoop(userMessage: string, maxIterations = 10): Promise<string> {
  const messages: OpenAI.Chat.ChatCompletionMessageParam[] = [
    { role: "user", content: userMessage }
  ];

  for (let i = 0; i < maxIterations; i++) {
    const response = await openai.chat.completions.create({
      model: "gpt-4o",
      messages,
      tools: TOOL_DEFINITIONS,
    });

    const choice = response.choices[0];
    messages.push(choice.message);

    if (choice.finish_reason !== "tool_calls") {
      return choice.message.content ?? "";
    }

    for (const toolCall of choice.message.tool_calls ?? []) {
      try {
        const result = await executeTool(
          toolCall.function.name,
          JSON.parse(toolCall.function.arguments)
        );
        messages.push({ role: "tool", tool_call_id: toolCall.id, content: result });
      } catch (err) {
        // Feed error back to LLM so it can recover or stop
        messages.push({ role: "tool", tool_call_id: toolCall.id, content: `Error: ${(err as Error).message}` });
      }
    }
  }
  throw new Error(`Agent loop exceeded ${maxIterations} iterations`);
}
```

---

### 5. LLM Error Handling

LLM APIs fail with rate limits (429), server errors (500/503), and timeouts. Handle each class distinctly.

**Red Flags:**
- No retry on 429 — fails immediately when rate limited
- No timeout on streaming calls — hangs indefinitely on network partition
- Single model dependency — no fallback when primary model is degraded
- Retrying 400 (bad request) — permanent errors wasted on retries

**TypeScript:**
```typescript
import { OpenAI, APIError, RateLimitError, APIConnectionTimeoutError } from "openai";

const PRIMARY_MODEL = "gpt-4o";
const FALLBACK_MODEL = "gpt-4o-mini";

interface LlmCallOptions {
  maxAttempts?: number;
  timeoutMs?: number;
  useFallback?: boolean;
}

async function callLlmWithRetry(
  messages: OpenAI.Chat.ChatCompletionMessageParam[],
  options: LlmCallOptions = {}
): Promise<string> {
  const { maxAttempts = 3, timeoutMs = 30_000, useFallback = true } = options;
  const openai = new OpenAI({ timeout: timeoutMs });

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const model = attempt === maxAttempts && useFallback ? FALLBACK_MODEL : PRIMARY_MODEL;
    try {
      const response = await openai.chat.completions.create({ model, messages });
      return response.choices[0].message.content ?? "";
    } catch (err) {
      if (err instanceof RateLimitError) {
        if (attempt === maxAttempts) throw err;
        const retryAfter = Number(err.headers?.["retry-after"] ?? 2 ** attempt);
        await new Promise(r => setTimeout(r, retryAfter * 1000));
      } else if (err instanceof APIConnectionTimeoutError) {
        if (attempt === maxAttempts) throw err;
        await new Promise(r => setTimeout(r, 1000 * attempt));
      } else if (err instanceof APIError && err.status >= 400 && err.status < 500) {
        throw err;  // permanent client errors — do not retry
      } else {
        if (attempt === maxAttempts) throw err;
        await new Promise(r => setTimeout(r, 500 * 2 ** (attempt - 1)));
      }
    }
  }
  throw new Error("unreachable");
}
```

**Python:**
```python
import time
import anthropic
from anthropic import RateLimitError, APITimeoutError, APIStatusError

client = anthropic.Anthropic()

def call_llm_with_retry(
    messages: list[dict],
    max_attempts: int = 3,
    timeout: float = 30.0,
    fallback_model: str = "claude-haiku-4-5",
    primary_model: str = "claude-sonnet-4-6",
) -> str:
    for attempt in range(1, max_attempts + 1):
        model = fallback_model if attempt == max_attempts else primary_model
        try:
            response = client.messages.create(
                model=model,
                max_tokens=2048,
                messages=messages,
                timeout=timeout,
            )
            return response.content[0].text
        except RateLimitError as e:
            if attempt == max_attempts:
                raise
            retry_after = float(e.response.headers.get("retry-after", 2 ** attempt))
            time.sleep(retry_after)
        except APITimeoutError:
            if attempt == max_attempts:
                raise
            time.sleep(attempt)
        except APIStatusError as e:
            if 400 <= e.status_code < 500:
                raise  # permanent — do not retry
            if attempt == max_attempts:
                raise
            time.sleep(0.5 * 2 ** (attempt - 1))
```

Cross-reference: `error-handling-patterns` — Retry with Exponential Backoff for generic retry utilities.
Cross-reference: `api-rate-limiting-throttling` — rate limit detection and backoff strategies.

---

### 6. Token Budget Management

Exceeding the context window causes runtime errors. Unbounded context assembly silently inflates costs.

**Strategies:**
- **Counting** — measure token usage before sending requests
- **Truncation** — trim least-relevant content to fit the budget
- **Chunking** — split large documents into overlapping windows for processing
- **Priority packing** — allocate tokens by priority: system prompt > recent history > retrieved context

**Red Flags:**
- No token count check before assembling the final prompt
- Entire conversation history appended — grows unbounded over multi-turn sessions
- Chunk size set in characters, not tokens — off by 3-4x for non-ASCII content
- Overlap between chunks ignored — sentence boundaries split mid-thought

**TypeScript:**
```typescript
import { encode, decode } from "gpt-tokenizer";

const MODEL_TOKEN_LIMITS: Record<string, number> = {
  "gpt-4o": 128_000,
  "gpt-4o-mini": 128_000,
  "gpt-4-turbo": 128_000,
};

function countTokens(text: string): number {
  return encode(text).length;
}

function truncateToTokenBudget(text: string, maxTokens: number): string {
  const tokens = encode(text);
  if (tokens.length <= maxTokens) return text;
  return decode(tokens.slice(0, maxTokens));
}

interface ChunkOptions {
  chunkSizeTokens: number;
  overlapTokens: number;
}

function chunkDocument(text: string, options: ChunkOptions): string[] {
  const { chunkSizeTokens, overlapTokens } = options;
  const tokens = encode(text);
  const chunks: string[] = [];
  let start = 0;

  while (start < tokens.length) {
    const end = Math.min(start + chunkSizeTokens, tokens.length);
    chunks.push(decode(tokens.slice(start, end)));
    start += chunkSizeTokens - overlapTokens;
    if (start >= tokens.length) break;
  }
  return chunks;
}

function buildPromptWithBudget(
  systemPrompt: string,
  history: Array<{ role: string; content: string }>,
  userMessage: string,
  model = "gpt-4o"
): Array<{ role: string; content: string }> {
  const limit = MODEL_TOKEN_LIMITS[model] ?? 8_000;
  const reservedForOutput = 2_048;
  let budget = limit - reservedForOutput;

  const systemTokens = countTokens(systemPrompt);
  const userTokens = countTokens(userMessage);
  budget -= systemTokens + userTokens;

  // Include history from newest to oldest until budget exhausted
  const includedHistory: typeof history = [];
  for (let i = history.length - 1; i >= 0 && budget > 0; i--) {
    const t = countTokens(history[i].content);
    if (t > budget) break;
    includedHistory.unshift(history[i]);
    budget -= t;
  }

  return [
    { role: "system", content: systemPrompt },
    ...includedHistory,
    { role: "user", content: userMessage },
  ];
}
```

---

### 7. Hallucination Mitigation and Grounding

LLMs generate plausible-sounding but false information. Mitigation requires architectural controls — prompting alone is insufficient.

**Techniques:**
- **Source citation** — require the model to cite which document each claim comes from
- **Confidence scoring** — ask the model to rate certainty; threshold low-confidence answers
- **Guardrails** — post-process outputs to detect and block unsafe or off-topic responses
- **Grounding checks** — verify claims against the retrieved context programmatically
- **Abstain instruction** — explicitly instruct the model to say "I don't know" rather than guess

**Red Flags:**
- LLM answers without any retrieved context — no grounding possible
- No instruction to abstain when uncertain — model invents answers
- Guardrails applied only at the prompt level — no post-processing safety layer
- Citations not verified against actual source content

**TypeScript:**
```typescript
interface GroundedAnswer {
  answer: string;
  citations: Array<{ sourceId: string; excerpt: string }>;
  confidence: "high" | "medium" | "low";
  abstained: boolean;
}

const GROUNDED_SYSTEM_PROMPT = `You are a factual question-answering assistant.
Rules:
1. Answer ONLY using information from the provided context.
2. For each claim, cite the source ID in brackets: [source-1].
3. If the answer is not in the context, respond with: {"abstained": true, "answer": "I don't have enough information.", "citations": [], "confidence": "low"}
4. Rate your confidence as "high", "medium", or "low".
5. Respond ONLY with valid JSON matching this schema:
   {"answer": string, "citations": [{"sourceId": string, "excerpt": string}], "confidence": "high"|"medium"|"low", "abstained": boolean}`;

import { z } from "zod";

const GroundedAnswerSchema = z.object({
  answer: z.string(),
  citations: z.array(z.object({ sourceId: z.string(), excerpt: z.string() })),
  confidence: z.enum(["high", "medium", "low"]),
  abstained: z.boolean(),
});

async function groundedQuery(
  question: string,
  context: string,
  openai: import("openai").OpenAI
): Promise<GroundedAnswer> {
  const response = await openai.chat.completions.create({
    model: "gpt-4o",
    response_format: { type: "json_object" },
    messages: [
      { role: "system", content: GROUNDED_SYSTEM_PROMPT },
      { role: "user", content: `Context:\n${context}\n\nQuestion: ${question}` },
    ],
    temperature: 0,
  });

  const raw = JSON.parse(response.choices[0].message.content ?? "{}");
  const result = GroundedAnswerSchema.parse(raw);

  // Post-hoc guardrail: flag low-confidence answers for review
  if (result.confidence === "low" && !result.abstained) {
    console.warn("Low-confidence answer returned without abstaining", { question });
  }
  return result;
}
```

**Python — guardrail post-processing:**
```python
import re
from dataclasses import dataclass

@dataclass
class GuardrailResult:
    safe: bool
    reason: str | None

BLOCKED_PATTERNS = [
    re.compile(r"\b(password|api[_\s]key|secret[_\s]key|token)\b", re.IGNORECASE),
    re.compile(r"\b(ssn|social.security|credit.card)\b", re.IGNORECASE),
]

def apply_output_guardrails(text: str) -> GuardrailResult:
    """Post-process LLM output before returning to caller."""
    for pattern in BLOCKED_PATTERNS:
        if pattern.search(text):
            return GuardrailResult(safe=False, reason=f"Sensitive pattern detected: {pattern.pattern}")
    return GuardrailResult(safe=True, reason=None)

def safe_generate(prompt: str, client, model: str = "claude-sonnet-4-6") -> str:
    import anthropic
    response = client.messages.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    text = response.content[0].text
    result = apply_output_guardrails(text)
    if not result.safe:
        raise ValueError(f"Output blocked by guardrail: {result.reason}")
    return text
```

Cross-reference: `security-patterns-code-review` — input/output sanitization and injection prevention.

---

### 8. AI/ML Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Prompt Injection** | User input injected directly into system prompt — attacker controls model behavior | Separate user input from system instructions; sanitize or encode user content |
| **Unbounded Context** | Full conversation history appended forever — token cost grows linearly | Implement rolling window or summarization; enforce token budget per request |
| **No Output Validation** | Raw LLM JSON used as typed data without schema check | Always validate with Zod (TS) or Pydantic (Python) before use |
| **Hardcoded Prompts** | Prompts inline in application code — no versioning, no A/B testing | Store prompts in config, database, or prompt management system |
| **Retry All Errors** | Retrying 400 Bad Request or 404 Not Found — permanent errors waste quota | Classify errors: transient (429, 503) vs. permanent (400, 401, 404) |
| **No Timeout** | LLM call with no timeout — hangs indefinitely on network failure | Always set request timeout; use streaming with read timeout |
| **Single Model Dependency** | No fallback model — one provider outage causes full outage | Define primary + fallback model; implement model router |
| **Ignoring Token Costs** | No token counting or budget — surprise bills at end of month | Count tokens before each request; set max_tokens on all calls |
| **Trusting LLM for Logic** | Using LLM to make security, financial, or access control decisions | LLM output is advisory only; enforce business rules in deterministic code |

**Prompt Injection — TypeScript fix:**
```typescript
// WRONG — user input directly in system prompt
const systemPrompt = `You are a helpful assistant. User context: ${userProvidedContext}`;

// CORRECT — strict separation of system instructions and user content
const systemPrompt = `You are a helpful assistant. Answer questions about our product catalog only.
If asked to do anything outside this scope, politely decline.`;

const messages = [
  { role: "system" as const, content: systemPrompt },
  // User content is ALWAYS in user role, never interpolated into system
  { role: "user" as const, content: userMessage },
];
```

**Unbounded context — Python fix:**
```python
# WRONG — history grows forever
messages = system_messages + all_history + [new_message]

# CORRECT — rolling window with token budget
def trim_history(history: list[dict], max_tokens: int = 4000) -> list[dict]:
    import tiktoken
    enc = tiktoken.encoding_for_model("gpt-4o")
    trimmed, token_count = [], 0
    for msg in reversed(history):
        tokens = len(enc.encode(msg["content"]))
        if token_count + tokens > max_tokens:
            break
        trimmed.insert(0, msg)
        token_count += tokens
    return trimmed

messages = system_messages + trim_history(history) + [new_message]
```

---

## Cross-References

- `error-handling-patterns` — Retry with Exponential Backoff: retry primitives reusable for LLM API calls
- `data-validation-schema-patterns` — Zod and Pydantic schema definitions for structured output validation
- `api-rate-limiting-throttling` — rate limit detection, quota management, and backoff strategies for API calls
- `security-patterns-code-review` — input sanitization and output encoding to prevent prompt injection
- `observability-patterns` — tracing LLM calls: latency, token usage, model, prompt version as span attributes
