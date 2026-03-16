---
name: distributed-tracing-patterns
description: Use when instrumenting distributed systems or reviewing tracing code — covers OpenTelemetry auto and manual instrumentation, span design, context propagation (W3C TraceContext, B3), sampling strategies (head, tail, probabilistic, rate-limiting), trace-based testing, exemplars, and anti-patterns (over-instrumentation, missing context, span explosion) across TypeScript, Go, Java, and Python
---

# Distributed Tracing Patterns

## Overview

Distributed tracing records the journey of a request across services, processes, and machines as a tree of spans. Without proper instrumentation, diagnosing latency in a microservices system requires guesswork. Done poorly — missing context propagation, over-instrumentation, or span explosion — tracing creates noise and cost without insight.

**When to use:** Instrumenting a new service, reviewing tracing code, debugging latency across service boundaries, linking traces to metrics, or designing a sampling strategy for high-throughput systems.

**Prerequisite skills:** `observability-patterns` (metrics, logs, correlation IDs), `microservices-resilience-patterns` (circuit breakers, retries), `performance-anti-patterns` (identifying latency hotspots).

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

OpenTelemetry (OTEL) is the standard SDK for producing traces, metrics, and logs. Auto-instrumentation hooks into popular frameworks (HTTP servers, database drivers, message brokers) without code changes. Manual instrumentation adds spans for business logic the framework cannot see.

**Auto-instrumentation — when to use:**
- HTTP ingress/egress, database queries, cache calls, message consumers
- Any operation a framework library already wraps

**Manual instrumentation — when to use:**
- Long business transactions within a single HTTP handler
- Batch processing loops where per-item spans matter
- Background jobs and scheduled tasks not covered by framework hooks

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
    new HttpInstrumentation(),       // auto: all inbound + outbound HTTP
    new ExpressInstrumentation(),    // auto: Express route handlers
    new PgInstrumentation(),         // auto: PostgreSQL queries
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

**Go — OTEL SDK + manual span:**
```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    otlphttp "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer(ctx context.Context) (func(), error) {
    exp, err := otlphttp.New(ctx)
    if err != nil { return nil, err }
    tp := trace.NewTracerProvider(
        trace.WithBatcher(exp),
        trace.WithResource(resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceNameKey.String("order-service"),
        )),
    )
    otel.SetTracerProvider(tp)
    return func() { _ = tp.Shutdown(ctx) }, nil
}

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

**Java — OpenTelemetry Java agent (auto) + manual annotation:**
```java
// Auto-instrumentation: attach -javaagent:opentelemetry-javaagent.jar at startup
// JVM flags: -Dotel.service.name=order-service -Dotel.exporter.otlp.endpoint=http://collector:4317

// Manual annotation (requires opentelemetry-instrumentation-annotations):
@WithSpan("order.validate-inventory")
public void validateInventory(@SpanAttribute("order.id") String orderId) {
    // OTEL annotation creates child span automatically
}

// Manual programmatic:
Tracer tracer = GlobalOpenTelemetry.getTracer("order-service", "1.0.0");
Span span = tracer.spanBuilder("order.process")
    .setAttribute("order.id", orderId)
    .startSpan();
try (Scope scope = span.makeCurrent()) {
    chargePayment(orderId);
    span.setStatus(StatusCode.OK);
} catch (Exception e) {
    span.recordException(e);
    span.setStatus(StatusCode.ERROR, e.getMessage());
    throw e;
} finally {
    span.end();
}
```

**Python — opentelemetry-sdk + auto-instrumentation bootstrap:**
```python
# Install: pip install opentelemetry-distro && opentelemetry-bootstrap --action=install
# Run: opentelemetry-instrument --service-name=order-service python app.py

from opentelemetry import trace
from opentelemetry.trace import StatusCode

tracer = trace.get_tracer("order-service", "1.0.0")

def process_order(order_id: str) -> None:
    with tracer.start_as_current_span("order.process") as span:
        span.set_attribute("order.id", order_id)
        try:
            charge_payment(order_id)
            span.set_status(StatusCode.OK)
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(StatusCode.ERROR, str(exc))
            raise
```

---

### 2. Span Design — Naming, Attributes, and Status Codes

Span design governs whether a trace is readable in 30 seconds or incomprehensible in 30 minutes.

**Naming conventions:**

Use `<verb> <noun>` in `snake_case` or `dot.notation`. Follow OpenTelemetry semantic conventions as the authoritative taxonomy:

| Operation type | Convention | Example |
|---------------|-----------|---------|
| HTTP server | `HTTP <METHOD>` | `HTTP GET` |
| HTTP client | `HTTP <METHOD>` | `HTTP POST` |
| Database | `<db.operation> <db.name>.<table>` | `SELECT orders.payments` |
| Message consumer | `<topic> receive` | `payments.events receive` |
| Business operation | `<service>.<verb>` | `order.process` |

**Red flags in span naming:**
- `"GET /users/" + userId` — dynamic IDs create cardinality explosion
- `"step1"`, `"temp"`, `"test"` — meaningless names
- `"handleRequest"` — too generic; not distinguishable across services

**Attribute taxonomy:**

Attributes are key-value metadata attached to a span. Use OTEL semantic convention keys for common attributes:

```typescript
// CORRECT — semantic convention keys, bounded values
span.setAttributes({
  'http.method': 'POST',
  'http.url': 'https://payments.internal/charge',  // no tokens in URL
  'http.status_code': 200,
  'db.system': 'postgresql',
  'db.name': 'orders',
  'db.operation': 'INSERT',
  'order.id': orderId,           // domain attribute — bounded value
  'order.items.count': 3,        // numeric — queryable
});

// WRONG — unbounded string values, sensitive data
span.setAttributes({
  'user.email': email,           // PII — do not trace
  'query': sqlString,            // may contain sensitive data
  'response.body': JSON.stringify(resp),  // unbounded size
});
```

**Status codes:**

| Status | When to use |
|--------|------------|
| `UNSET` | Default; span completed normally (most spans) |
| `OK` | Explicitly verified success (use sparingly) |
| `ERROR` | An error the caller would want to investigate |

Do NOT set `ERROR` on expected 404s or 400s — this pollutes alerting. Set `ERROR` only on unexpected failures (5xx, network errors, business rule violations that break the SLA).

---

### 3. Context Propagation — W3C TraceContext and B3 Headers

Context propagation carries the trace ID and span ID across process boundaries so spans from multiple services are linked into one trace tree.

**W3C TraceContext (recommended — RFC 7230):**
```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^^ version  ^^ trace-id (128 bit)           ^^ parent-span-id (64 bit)  ^^ flags
tracestate:  vendor-specific additional state (optional)
```

**B3 (legacy Zipkin — still common in older Java ecosystems):**
```
X-B3-TraceId: 463ac35c9f6413ad48485a3953bb6124
X-B3-SpanId:  a2fb4a1d1a96d312
X-B3-Sampled: 1
```

OTEL defaults to W3C. Configure composite propagators for mixed environments:

```go
// Go — composite propagator: W3C + B3 for legacy systems
import (
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/contrib/propagators/b3"
)

otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
    propagation.TraceContext{},  // W3C — preferred
    propagation.Baggage{},
    b3.New(),                    // B3 — for legacy Zipkin consumers
))
```

```java
// Java — set propagators before SDK init
OpenTelemetrySdk.builder()
    .setPropagators(ContextPropagators.create(
        TextMapPropagator.composite(
            W3CTraceContextPropagator.getInstance(),
            B3Propagator.injectingMultiHeaders()
        )
    ))
    .buildAndRegisterGlobal();
```

**Manual propagation (message queues, async tasks):**

HTTP frameworks inject/extract automatically. For async work (Kafka, SQS, job queues), propagate manually:

```typescript
// Producer — inject context into message headers
import { propagation, context } from '@opentelemetry/api';

function publishEvent(topic: string, payload: object): void {
  const carrier: Record<string, string> = {};
  propagation.inject(context.active(), carrier);   // writes traceparent header
  kafkaProducer.send({ topic, messages: [{ headers: carrier, value: JSON.stringify(payload) }] });
}

// Consumer — extract context from message headers
function consumeEvent(message: KafkaMessage): void {
  const ctx = propagation.extract(context.active(), message.headers ?? {});
  context.with(ctx, () => {
    tracer.startActiveSpan('payments.events receive', (span) => {
      // span is now a child of the producer's span
      handleEvent(JSON.parse(message.value!.toString()));
      span.end();
    });
  });
}
```

```python
# Python — manual propagation for Celery tasks
from opentelemetry.propagate import inject, extract
from opentelemetry import context, trace

def dispatch_task(payload: dict) -> None:
    carrier: dict = {}
    inject(carrier)  # writes traceparent into carrier dict
    celery_task.apply_async(args=[payload], headers=carrier)

@app.task(bind=True)
def process_task(self, payload: dict) -> None:
    ctx = extract(self.request.headers or {})
    with trace.use_span(
        trace.get_tracer(__name__).start_span("task.process", context=ctx)
    ):
        handle_payload(payload)
```

**Red flags in context propagation:**
- Fire-and-forget async calls that never extract the incoming context
- HTTP clients that strip `traceparent` before forwarding (e.g., proxy config)
- Manual `trace_id` logging without linking to the trace context object
- Propagating context across trust boundaries without scrubbing `tracestate`

---

### 4. Sampling Strategies

Tracing every request at full fidelity is cost-prohibitive at scale. Sampling controls which traces are recorded.

**Head sampling — decision at trace root:**

The sampling decision is made when the first span starts (at the root service). The decision propagates in the `traceparent` flags field so all downstream services follow it.

```go
// Go — probabilistic head sampler at 10%
tp := trace.NewTracerProvider(
    trace.WithSampler(trace.TraceIDRatioBased(0.10)),
)

// Always sample for specific routes (priority sampling)
type prioritySampler struct{ base trace.Sampler }
func (s prioritySampler) ShouldSample(p trace.SamplingParameters) trace.SamplingResult {
    if strings.HasPrefix(p.Name, "checkout.") {
        return trace.AlwaysSample().ShouldSample(p)
    }
    return s.base.ShouldSample(p)
}
```

**Tail sampling — decision after span collection:**

All spans are buffered in the collector. The decision is made based on the complete trace (e.g., "keep all traces with ERROR spans" or "keep all traces over 2 seconds"). Requires a stateful collector (OpenTelemetry Collector tail sampling processor).

```yaml
# OpenTelemetry Collector — tail sampling processor config
processors:
  tail_sampling:
    decision_wait: 10s          # buffer window to collect all spans
    num_traces: 100000          # max traces in memory
    expected_new_traces_per_sec: 1000
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

**Probabilistic sampling — uniform rate:**

Simple and stateless. Set a fixed percentage (e.g., 1 in 100 traces). Misses rare slow paths if the rate is too low.

```python
# Python — 5% probabilistic head sampling
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased

sampler = TraceIdRatioBased(0.05)  # 5% of traces
```

**Rate-limiting sampling — fixed count per second:**

Caps spans to N per second regardless of traffic volume. Useful for services with highly variable throughput.

```java
// Java — rate-limiting sampler via OTEL config
// env: OTEL_TRACES_SAMPLER=parentbased_traceidratio
// env: OTEL_TRACES_SAMPLER_ARG=0.01  (1%)
// Or programmatically with a custom sampler:

public class RateLimitingSampler implements Sampler {
    private final RateLimiter limiter;
    public RateLimitingSampler(double tracesPerSecond) {
        this.limiter = RateLimiter.create(tracesPerSecond);
    }
    @Override
    public SamplingResult shouldSample(Context parentContext, String traceId,
            String name, SpanKind kind, Attributes attributes, List<LinkData> links) {
        if (limiter.tryAcquire()) {
            return SamplingResult.recordAndSample();
        }
        return SamplingResult.drop();
    }
    @Override public String getDescription() { return "RateLimitingSampler"; }
}
```

**Sampling strategy selection guide:**

| Strategy | Best for | Avoid when |
|----------|---------|-----------|
| Head probabilistic | High-volume, homogeneous traffic | Need to capture all errors or slow traces |
| Head rate-limiting | Bursty traffic, cost control | Need representative statistical sample |
| Tail sampling | Need error and latency capture guarantees | Simple setups; adds collector complexity |
| Always-on | Low-volume, critical paths (e.g., payment flows) | High-volume endpoints — cost explosion |
| Parent-based | Respecting upstream sampling decision | You are the root service |

---

### 5. Trace-Based Testing and Debugging Workflows

Traces are not just operational tools — they are a testing artifact. Trace-based testing asserts on the shape and content of the trace produced by a workflow.

**Integration test asserting span structure:**

```typescript
// TypeScript — in-memory OTEL exporter for testing
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
  expect(chargeSpan).toBeDefined();
  expect(chargeSpan!.parentSpanId).toBe(root!.spanContext().spanId);
});
```

**Go — trace assertion with in-memory exporter:**
```go
import (
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    "go.opentelemetry.io/otel/sdk/trace/tracetest"
)

func TestProcessOrder(t *testing.T) {
    exporter := tracetest.NewInMemoryExporter()
    tp := sdktrace.NewTracerProvider(sdktrace.WithSyncer(exporter))
    otel.SetTracerProvider(tp)

    err := processOrder(context.Background(), "order-42")
    require.NoError(t, err)

    spans := exporter.GetSpans()
    require.Len(t, spans, 3)  // root + 2 child spans

    root := spans[0]
    assert.Equal(t, "order.process", root.Name)
    assert.Equal(t, attribute.StringValue("order-42"), root.Attributes[0].Value)
    assert.Equal(t, codes.Ok, root.Status.Code)
}
```

**Debugging workflow with traces:**

1. Identify the slow or failing request from your APM tool (Jaeger, Tempo, Honeycomb, Datadog APM).
2. Find the trace ID — from a log correlation, Exemplar link, or error alert.
3. In the trace waterfall, locate the longest span or the first `ERROR` span.
4. Inspect span attributes (`db.statement`, `http.url`, `order.id`) to narrow scope.
5. Check gap between parent span start and first child span start — this gap is often network, serialization, or lock contention.
6. If a span is missing (expected child not present), the context was likely dropped — check async call sites and message producer/consumer pairs.

---

### 6. Exemplars — Linking Traces to Metrics

Exemplars embed a trace ID and timestamp into a metric data point, creating a direct link from a histogram bucket or gauge observation to the trace that produced it.

**Why exemplars matter:** Without exemplars, you know *that* p99 latency spiked but not *which* request caused it. With exemplars, one click in Grafana takes you from the metric spike to the exact trace.

**Prometheus + OTEL exemplar setup:**
```typescript
// TypeScript — OTEL Prometheus exporter with exemplars enabled
import { MeterProvider } from '@opentelemetry/sdk-metrics';
import { PrometheusExporter } from '@opentelemetry/exporter-prometheus';

const exporter = new PrometheusExporter({ appendTimestamp: true });
const meterProvider = new MeterProvider({ readers: [exporter] });
const meter = meterProvider.getMeter('order-service');

const requestDuration = meter.createHistogram('http.request.duration', {
  description: 'HTTP request duration in ms',
  unit: 'ms',
});

// Recording a metric with an exemplar (trace ID is auto-attached from active context)
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    requestDuration.record(Date.now() - start, {
      'http.method': req.method,
      'http.status_code': res.statusCode,
    });
    // OTEL SDK attaches trace_id + span_id from active context automatically
  });
  next();
});
```

**Java — Micrometer + OTEL exemplar bridge:**
```java
// Requires: micrometer-tracing-bridge-otel dependency
@Bean
MeterRegistry meterRegistry(OpenTelemetry openTelemetry) {
    return new PrometheusMeterRegistry(PrometheusConfig.DEFAULT)
        .withContext(ObservationRegistry.create()
            .observationConfig()
            .observationHandler(new OpenTelemetryObservationHandler(openTelemetry)));
}

// Automatic exemplar attachment with @Timed
@Timed(value = "order.process.duration", histogram = true)
public void processOrder(String orderId) { /* trace_id linked automatically */ }
```

**Grafana — querying exemplars:**
```promql
# Enable exemplars in Grafana data source config (Prometheus > Exemplars toggle)
# Query: histogram showing p99 with exemplar dots
histogram_quantile(0.99, rate(http_request_duration_bucket[5m]))
# Click any exemplar dot → opens linked trace in Tempo/Jaeger
```

**metric to trace linking** requires that your metric and trace SDKs share the same active context. If metrics are recorded outside a span, no exemplar can be attached — this is a silent gap.

---

### 7. Distributed Tracing Anti-Patterns

#### Anti-Pattern: Over-Instrumentation

Adding a span to every function call produces traces with hundreds of spans where only five are meaningful. Reviewers give up reading them.

**Detection:** Trace has more than 50 spans for a single user request; span names like `getField`, `setProperty`, `toString`.

**Fix:** Span only at I/O boundaries (HTTP, DB, cache, queue) and significant business operations (checkout, payment, auth). Internal pure functions do not need spans.

#### Anti-Pattern: Missing Context Propagation

Async calls (fire-and-forget tasks, message queues, thread pools) that do not carry the trace context produce orphaned traces — disconnected spans that cannot be correlated to the root cause.

```go
// WRONG — goroutine loses context
go func() { processNotification(orderId) }()

// CORRECT — pass context explicitly
go func(ctx context.Context) { processNotification(ctx, orderId) }(ctx)
```

#### Anti-Pattern: Span Explosion (Cardinality)

Dynamic values in span names or attribute keys create millions of unique series, exhausting collector memory and making queries impossible.

```python
# WRONG — orderId in span name = unbounded cardinality
with tracer.start_as_current_span(f"process-order-{order_id}"):
    ...

# CORRECT — stable name, dynamic value as attribute
with tracer.start_as_current_span("order.process") as span:
    span.set_attribute("order.id", order_id)
```

#### Anti-Pattern: Logging the Trace ID Instead of Using Context

Manually writing `trace_id=xxx` to logs without wiring it to the OTEL context means you cannot click through from a log to the trace in your APM tool.

```typescript
// WRONG — manual string in log, not linked to OTEL context
logger.info(`trace_id=${traceId} order processed`);

// CORRECT — inject active span context into log metadata
import { trace } from '@opentelemetry/api';
const span = trace.getActiveSpan();
const { traceId, spanId } = span?.spanContext() ?? { traceId: '', spanId: '' };
logger.info('order processed', { traceId, spanId });  // structured; correlatable
```

#### Anti-Pattern: Incorrect Span Status

Setting `ERROR` on every non-2xx response pollutes error-rate dashboards and drowns out real failures.

| HTTP Status | Span status |
|------------|------------|
| 2xx | OK or UNSET |
| 4xx (client error) | UNSET (expected — not a service failure) |
| 5xx (server error) | ERROR |
| Network timeout | ERROR |
| Business rule violation | ERROR only if it breaks SLA |

#### Anti-Pattern: Unbounded Attribute Values

Recording raw SQL strings, full HTTP response bodies, or user-provided data as span attributes inflates storage, may expose PII, and makes queries unusable.

```java
// WRONG
span.setAttribute("db.statement", rawSql);           // may contain passwords
span.setAttribute("response.body", responseJson);    // unbounded size

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
- `microservices-resilience-patterns` — Circuit breakers and retries: instrument retry attempts as child spans with `retry.attempt` attribute; span status `ERROR` should trigger circuit breaker awareness
- `performance-anti-patterns` — N+1 queries and slow operations: use database span attributes (`db.operation`, `db.table`) to identify patterns; sort trace waterfall by duration to find hotspots
- `concurrency-patterns` — Async/Await Pitfalls: fire-and-forget tasks that drop context are a direct cause of broken trace trees; see context propagation section above
- `error-handling-patterns` — Error propagation: `span.recordException(err)` should accompany every `throw`; ensures the exception is visible in the trace alongside the stack trace in logs
