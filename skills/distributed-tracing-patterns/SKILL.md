---
name: distributed-tracing-patterns
description: Use when instrumenting distributed systems or reviewing tracing code — covers OpenTelemetry auto and manual instrumentation, span design, context propagation (W3C TraceContext, B3), sampling strategies (head, tail, probabilistic, rate-limiting), trace-based testing, exemplars, and anti-patterns (over-instrumentation, missing context, span explosion) across TypeScript, Go, Java, and Python
---

# Distributed Tracing Patterns

## Overview

Distributed tracing records the journey of a request across services as a tree of spans. Without proper instrumentation, diagnosing latency in a microservices system requires guesswork. Done poorly — missing context propagation, over-instrumentation, or span explosion — tracing creates noise and cost without insight.

**When to use:** Instrumenting a new service, reviewing tracing code, debugging latency across service boundaries, linking traces to metrics, or designing a sampling strategy for high-throughput systems.

**Prerequisite skills:** `observability-patterns`, `microservices-resilience-patterns`, `performance-anti-patterns`.

## Quick Reference

| Topic | Core Idea | Primary Red Flag |
|-------|-----------|-----------------|
| Auto-instrumentation | Framework hooks inject spans with zero code change | Forgetting to add SDK; auto-spans are too coarse |
| Manual instrumentation | Code-level spans for business operations | Spans that duplicate auto-instrumented work |
| Span naming | `<verb> <noun>` using a stable taxonomy | Dynamic IDs in span names cause cardinality explosion |
| Span attributes | Semantic conventions for keys; bounded value sets | Free-text attribute values create unbounded cardinality |
| Span status | OK / ERROR / UNSET with description only on ERROR | Setting ERROR on expected 404s pollutes error rates |
| Context propagation | W3C TraceContext (`traceparent`) or B3 headers | Fire-and-forget calls that drop context |
| Head sampling | Decision made at trace root, propagated downstream | Sampling before context is set loses correlated spans |
| Tail sampling | Decision made after all spans collected | Requires stateful collector; complex to operate |
| Probabilistic sampling | Fixed rate (e.g., 1%) applied uniformly | Low-rate sampling misses rare slow paths |
| Rate-limiting sampling | Fixed span count per second | Spiky traffic bursts still get sampled proportionally |
| Exemplars | Attach trace ID to a metric data point | Metrics and traces in separate systems with no link |
| Over-instrumentation | More spans than needed obscures signal | Every line of code wrapped in a span |
| Span explosion | Dynamic span names or attributes create millions of series | `span.name = "GET /users/" + userId` |

---

## Patterns in Detail

### 1. OpenTelemetry Instrumentation — Auto vs. Manual

**Auto-instrumentation:** Framework hooks (HTTP servers, DB drivers, message brokers) with zero code changes.
**Manual instrumentation:** Add spans for business logic the framework cannot see — long transactions, batch loops, background jobs.

**TypeScript (Node.js) — auto + manual:**
```typescript
// sdk-setup.ts — register before any other imports
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { ExpressInstrumentation } from '@opentelemetry/instrumentation-express';
import { PgInstrumentation } from '@opentelemetry/instrumentation-pg';

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({ url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT }),
  instrumentations: [
    new HttpInstrumentation(),
    new ExpressInstrumentation(),
    new PgInstrumentation(),
  ],
});
sdk.start();

// app.ts — manual span for business logic
import { trace, SpanStatusCode } from '@opentelemetry/api';

const tracer = trace.getTracer('order-service', '1.0.0');

async function processOrder(orderId: string): Promise<void> {
  await tracer.startActiveSpan('order.process', async (span) => {
    span.setAttribute('order.id', orderId);
    try {
      await validateInventory(orderId);
      await chargePayment(orderId);
      await dispatchFulfillment(orderId);
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (err) {
      span.recordException(err as Error);
      span.setStatus({ code: SpanStatusCode.ERROR, message: (err as Error).message });
      throw err;
    } finally {
      span.end();
    }
  });
}
```

**Go — manual span (context passing is idiomatic):**
```go
func processOrder(ctx context.Context, orderID string) error {
    tracer := otel.Tracer("order-service")
    ctx, span := tracer.Start(ctx, "order.process",
        trace.WithAttributes(attribute.String("order.id", orderID)),
    )
    defer span.End()

    if err := chargePayment(ctx, orderID); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return fmt.Errorf("processOrder: %w", err)
    }
    return nil
}
```

**Java — auto via javaagent + annotation for manual:**
```java
// Auto: attach -javaagent:opentelemetry-javaagent.jar at startup
// JVM: -Dotel.service.name=order-service -Dotel.exporter.otlp.endpoint=http://collector:4317

@WithSpan("order.validate-inventory")
public void validateInventory(@SpanAttribute("order.id") String orderId) { }
```

---

### 2. Span Design — Naming, Attributes, and Status Codes

**Naming conventions** — `<verb> <noun>` in `snake_case` or `dot.notation`:

| Operation type | Convention | Example |
|---------------|-----------|---------|
| HTTP server/client | `HTTP <METHOD>` | `HTTP GET` |
| Database | `<db.operation> <db.name>.<table>` | `SELECT orders.payments` |
| Message consumer | `<topic> receive` | `payments.events receive` |
| Business operation | `<service>.<verb>` | `order.process` |

**Red flags:** `"GET /users/" + userId` (cardinality), `"step1"` (meaningless), `"handleRequest"` (too generic).

**Attribute taxonomy:**
```typescript
// CORRECT — semantic convention keys, bounded values
span.setAttributes({
  'http.method': 'POST',
  'http.status_code': 200,
  'db.system': 'postgresql',
  'db.operation': 'INSERT',
  'order.id': orderId,
  'order.items.count': 3,
});

// WRONG — PII, unbounded values
span.setAttributes({
  'user.email': email,                          // PII
  'response.body': JSON.stringify(resp),        // unbounded size
});
```

**Status codes:**

| Status | When to use |
|--------|------------|
| `UNSET` | Default; span completed normally |
| `OK` | Explicitly verified success (use sparingly) |
| `ERROR` | Unexpected failure the caller would investigate |

Set `ERROR` only on 5xx, network errors, and SLA-breaking business violations. NOT on 404s or 400s.

---

### 3. Context Propagation — W3C TraceContext and B3 Headers

**W3C TraceContext (recommended):**
```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^^ version  ^^ trace-id (128 bit)           ^^ parent-span-id  ^^ flags
tracestate:  vendor-specific additional state (optional)
```

**B3 (legacy Zipkin):**
```
X-B3-TraceId: 463ac35c9f6413ad48485a3953bb6124
X-B3-SpanId:  a2fb4a1d1a96d312
X-B3-Sampled: 1
```

**Go — composite propagator for mixed environments:**
```go
otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{},  // W3C — preferred
    propagation.Baggage{},
    b3.New(),                    // B3 — for legacy Zipkin consumers
))
```

**Manual propagation (message queues, async tasks):**

HTTP frameworks inject/extract automatically. For Kafka, SQS, and job queues, propagate manually:

```typescript
// Producer — inject context into message headers
import { propagation, context } from '@opentelemetry/api';

function publishEvent(topic: string, payload: object): void {
  const carrier: Record<string, string> = {};
  propagation.inject(context.active(), carrier);
  kafkaProducer.send({ topic, messages: [{ headers: carrier, value: JSON.stringify(payload) }] });
}

// Consumer — extract context from message headers
function consumeEvent(message: KafkaMessage): void {
  const ctx = propagation.extract(context.active(), message.headers ?? {});
  context.with(ctx, () => {
    tracer.startActiveSpan('payments.events receive', (span) => {
      handleEvent(JSON.parse(message.value!.toString()));
      span.end();
    });
  });
}
```

**Python — manual propagation for Celery tasks:**
```python
from opentelemetry.propagate import inject, extract

def dispatch_task(payload: dict) -> None:
    carrier: dict = {}
    inject(carrier)
    celery_task.apply_async(args=[payload], headers=carrier)

@app.task(bind=True)
def process_task(self, payload: dict) -> None:
    ctx = extract(self.request.headers or {})
    with trace.use_span(trace.get_tracer(__name__).start_span("task.process", context=ctx)):
        handle_payload(payload)
```

**Red Flags:**
- Fire-and-forget async calls that never extract the incoming context
- HTTP clients that strip `traceparent` before forwarding
- Manual `trace_id` logging without linking to the trace context object
- Propagating context across trust boundaries without scrubbing `tracestate`

---

### 4. Sampling Strategies

**Head sampling — decision at trace root:**
```go
// Go — probabilistic 10% + priority override for checkout flows
tp := trace.NewTracerProvider(
    trace.WithSampler(trace.TraceIDRatioBased(0.10)),
)

type prioritySampler struct{ base trace.Sampler }
func (s prioritySampler) ShouldSample(p trace.SamplingParameters) trace.SamplingResult {
    if strings.HasPrefix(p.Name, "checkout.") {
        return trace.AlwaysSample().ShouldSample(p)
    }
    return s.base.ShouldSample(p)
}
```

**Tail sampling — decision after span collection (OTEL Collector):**
```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    policies:
      - name: keep-errors
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: keep-slow-traces
        type: latency
        latency: { threshold_ms: 2000 }
      - name: probabilistic-base
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }
```

**Probabilistic (Python):**
```python
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased
sampler = TraceIdRatioBased(0.05)  # 5% of traces
```

**Rate-limiting sampler (Java — unique custom Sampler interface):**
```java
public class RateLimitingSampler implements Sampler {
    private final RateLimiter limiter;
    public RateLimitingSampler(double tracesPerSecond) {
        this.limiter = RateLimiter.create(tracesPerSecond);
    }
    @Override
    public SamplingResult shouldSample(Context parentContext, String traceId,
            String name, SpanKind kind, Attributes attributes, List<LinkData> links) {
        return limiter.tryAcquire()
            ? SamplingResult.recordAndSample()
            : SamplingResult.drop();
    }
    @Override public String getDescription() { return "RateLimitingSampler"; }
}
```

**Strategy selection guide:**

| Strategy | Best for | Avoid when |
|----------|---------|-----------|
| Head probabilistic | High-volume, homogeneous traffic | Need to capture all errors or slow traces |
| Head rate-limiting | Bursty traffic, cost control | Need representative statistical sample |
| Tail sampling | Error and latency capture guarantees | Simple setups; adds collector complexity |
| Always-on | Low-volume, critical paths (payments) | High-volume endpoints — cost explosion |
| Parent-based | Respecting upstream sampling decision | You are the root service |

---

### 5. Trace-Based Testing and Debugging

**Integration test with in-memory exporter (TypeScript):**
```typescript
import { InMemorySpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';

let exporter: InMemorySpanExporter;

beforeEach(() => {
  exporter = new InMemorySpanExporter();
  const provider = new NodeTracerProvider();
  provider.addSpanProcessor(new SimpleSpanProcessor(exporter));
  provider.register();
});

afterEach(() => exporter.reset());

test('processOrder creates child spans with correct attributes', async () => {
  await processOrder('order-42');

  const spans = exporter.getFinishedSpans();
  const root = spans.find(s => s.name === 'order.process');
  expect(root).toBeDefined();
  expect(root!.attributes['order.id']).toBe('order-42');
  expect(root!.status.code).toBe(SpanStatusCode.OK);

  const chargeSpan = spans.find(s => s.name === 'payment.charge');
  expect(chargeSpan!.parentSpanId).toBe(root!.spanContext().spanId);
});
```

**Debugging workflow:**
1. Find the trace ID from APM (Jaeger, Tempo, Honeycomb, Datadog) via a log correlation or Exemplar link.
2. In the trace waterfall, locate the longest span or first `ERROR` span.
3. Inspect span attributes (`db.statement`, `http.url`, `order.id`) to narrow scope.
4. Check gap between parent span start and first child — often network, serialization, or lock contention.
5. Missing expected child span → context was likely dropped; check async call sites and message producer/consumer pairs.

---

### 6. Exemplars — Linking Traces to Metrics

Exemplars embed a trace ID into a metric data point — one click in Grafana goes from a p99 spike to the exact trace.

**TypeScript — OTEL Prometheus exporter (trace ID auto-attached from active context):**
```typescript
import { MeterProvider } from '@opentelemetry/sdk-metrics';
import { PrometheusExporter } from '@opentelemetry/exporter-prometheus';

const exporter = new PrometheusExporter({ appendTimestamp: true });
const meter = new MeterProvider({ readers: [exporter] }).getMeter('order-service');
const requestDuration = meter.createHistogram('http.request.duration', { unit: 'ms' });

app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    requestDuration.record(Date.now() - start, {
      'http.method': req.method,
      'http.status_code': res.statusCode,
    });
    // OTEL SDK auto-attaches trace_id + span_id from active context
  });
  next();
});
```

**Java — Spring `@Timed` with Micrometer-OTEL bridge:**
```java
// Requires: micrometer-tracing-bridge-otel
@Timed(value = "order.process.duration", histogram = true)
public void processOrder(String orderId) { /* trace_id linked automatically */ }
```

**Grafana PromQL:**
```promql
histogram_quantile(0.99, rate(http_request_duration_bucket[5m]))
# Click exemplar dot → linked trace in Tempo/Jaeger
```

Requires metric and trace SDKs to share the same active context. Recording metrics outside a span = no exemplar attached (silent gap).

---

### 7. Distributed Tracing Anti-Patterns

#### Anti-Pattern: Over-Instrumentation
**Detection:** >50 spans/request; span names like `getField`, `setProperty`. **Fix:** Span only at I/O boundaries and significant business operations. Internal pure functions do not need spans.

#### Anti-Pattern: Missing Context Propagation
```go
// WRONG — goroutine loses context
go func() { processNotification(orderId) }()

// CORRECT — pass context explicitly
go func(ctx context.Context) { processNotification(ctx, orderId) }(ctx)
```

#### Anti-Pattern: Span Explosion (Cardinality)
```python
# WRONG — orderId in span name = unbounded cardinality
with tracer.start_as_current_span(f"process-order-{order_id}"): ...

# CORRECT — stable name, dynamic value as attribute
with tracer.start_as_current_span("order.process") as span:
    span.set_attribute("order.id", order_id)
```

#### Anti-Pattern: Logging the Trace ID Instead of Using Context
```typescript
// WRONG — manual string, not linked in APM
logger.info(`trace_id=${traceId} order processed`);

// CORRECT — inject from active span context
const span = trace.getActiveSpan();
const { traceId, spanId } = span?.spanContext() ?? { traceId: '', spanId: '' };
logger.info('order processed', { traceId, spanId });
```

#### Anti-Pattern: Incorrect Span Status

| HTTP Status | Span status |
|------------|------------|
| 2xx | OK or UNSET |
| 4xx (client error) | UNSET (expected — not a service failure) |
| 5xx (server error) | ERROR |
| Network timeout | ERROR |

#### Anti-Pattern: Unbounded Attribute Values
```java
// WRONG
span.setAttribute("db.statement", rawSql);        // may contain passwords
span.setAttribute("response.body", responseJson); // unbounded size

// CORRECT
span.setAttribute("db.operation", "SELECT");
span.setAttribute("db.table", "orders");
span.setAttribute("response.size_bytes", responseJson.length());
```

---

## Anti-Patterns Summary Table

| Anti-Pattern | Detection Signal | Fix |
|-------------|-----------------|-----|
| **Over-instrumentation** | >50 spans/request; spans on pure functions | Span only I/O and business operations |
| **Missing context** | Orphaned traces; broken trace trees in APM | Pass `ctx` to goroutines/threads; extract from message headers |
| **Span explosion** | Cardinality alerts; collector OOM | Move dynamic values to attributes; stable span names |
| **Log trace ID manually** | `trace_id=` as string in logs, not linked in APM | Inject `span.spanContext()` into structured log fields |
| **Wrong span status** | Error rate alert on 404s | `ERROR` only for 5xx and unexpected failures |
| **Unbounded attributes** | High cardinality in APM attribute browser | Bounded enums and numeric values; no raw query strings |
| **Sampling too aggressive** | 0.01% sample rate misses all slow traces | Use tail sampling to guarantee error/latency trace capture |
| **Missing exemplars** | Can't trace from metric spike to request | Enable OTEL Prometheus exporter with exemplar support |

---

## Cross-References

- `observability-patterns` — Metrics, logs, and structured logging: use trace IDs as correlation keys; exemplars bridge this boundary
- `microservices-resilience-patterns` — Circuit breakers and retries: instrument retry attempts as child spans with `retry.attempt` attribute
- `performance-anti-patterns` — N+1 queries: use database span attributes (`db.operation`, `db.table`) to identify patterns
- `concurrency-patterns` — Fire-and-forget tasks that drop context are a direct cause of broken trace trees
- `error-handling-patterns` — `span.recordException(err)` should accompany every `throw`
