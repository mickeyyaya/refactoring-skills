---
name: data-pipeline-patterns
description: Use when reviewing or designing data pipelines — covers ETL vs ELT, batch vs streaming vs micro-batch selection, idempotency, exactly-once delivery, watermarking, checkpointing, dead letter queues, backpressure, schema evolution, data contracts, pipeline orchestration and DAG design, with anti-patterns and red flags across Python, SQL, and TypeScript
---

# Data Pipeline Patterns for Code Review

## Overview

Pipelines fail silently, duplicate records, or stall under backpressure — often in production, at scale, and without clear error messages. Use this guide when reviewing data ingestion, transformation, or delivery code to catch structural hazards before they cause data loss or corruption.

**When to use:** Reviewing ETL/ELT jobs, stream processors, batch schedulers, orchestration DAGs, message consumers, or any code that moves data between systems at scale.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| ETL vs ELT | Transform before or after load based on compute location | Transforming in application code when the warehouse can do it cheaper |
| Batch vs Streaming vs Micro-Batch | Select processing model to match latency and throughput requirements | Streaming when latency does not matter; polling when event triggers exist |
| Idempotency / Exactly-Once | Safe re-runs produce the same result | No idempotency key; INSERT without upsert guard; re-run creates duplicates |
| Watermarking / Checkpointing | Track progress so pipelines resume without reprocessing | No checkpoint state; always reprocessing from epoch on restart |
| Dead Letter Queue (DLQ) | Route unprocessable records for later inspection | Silently dropping failed records; no DLQ monitoring alert |
| Backpressure / Flow Control | Producer slows down when consumer cannot keep up | Unbounded in-memory queues; producer ignores consumer lag |
| Schema Evolution / Data Contracts | Backwards-compatible schema changes with explicit contracts | Breaking schema changes deployed without consumer coordination |
| Pipeline Orchestration / DAG | Explicit dependency graph with retries, SLAs, and alerting | Linear scripts with no dependency tracking, no retry, no alerting |

---

## Patterns in Detail

### 1. ETL vs ELT Decision Framework

**When to use ETL (Extract → Transform → Load):**
- Sensitive data must be masked or anonymized before entering the warehouse
- Target system has no compute capacity (legacy database, constrained storage)
- Transformation logic is complex and not expressible in SQL

**When to use ELT (Extract → Load → Transform):**
- Target is a modern analytical warehouse (BigQuery, Snowflake, Redshift, DuckDB)
- Raw data has audit / replay value — load first, transform later
- Transformations evolve frequently and are easier to iterate in SQL

**Red Flags:**
- Python loops doing row-by-row transformation that SQL `SELECT` could handle in one pass
- Transforming in the extraction layer, discarding raw data — no reprocessing path
- Loading into a staging table then transforming, but staging is never truncated — unbounded growth
- No separation between raw and transformed layers — impossible to re-derive from source

**Python ETL skeleton (PII masking before load):**
```python
import hashlib
from dataclasses import dataclass

@dataclass(frozen=True)
class RawRecord:
    user_id: str
    email: str
    amount: float

@dataclass(frozen=True)
class StagedRecord:
    user_id_hash: str
    amount: float

def mask(record: RawRecord) -> StagedRecord:
    """Mask PII before the record leaves the extraction layer."""
    return StagedRecord(
        user_id_hash=hashlib.sha256(record.user_id.encode()).hexdigest(),
        amount=record.amount,
    )

def etl_batch(records: list[RawRecord]) -> list[StagedRecord]:
    return [mask(r) for r in records]
```

**SQL ELT (transform inside warehouse after raw load):**
```sql
-- raw layer: loaded as-is from source
CREATE TABLE raw.events AS SELECT * FROM external_stage;

-- transformation layer: computed from raw
CREATE OR REPLACE TABLE analytics.daily_revenue AS
SELECT DATE(event_time) AS day, SUM(amount) AS revenue
FROM raw.events
WHERE event_type = 'purchase'
GROUP BY 1;
```

---

### 2. Batch Processing vs Streaming vs Micro-Batch

**Decision matrix:**

| Need | Choose |
|------|--------|
| Latency > 1 minute acceptable, large volumes | Batch |
| Latency < 1 second required, event-driven | Streaming |
| Latency 1-60 seconds, simplicity preferred | Micro-Batch |
| Incremental loads from OLTP to warehouse | Batch with CDC offset |

**Red Flags:**
- Polling a REST endpoint every 5 seconds when the source emits Kafka events — use streaming
- Streaming every row of a 500 GB nightly dump — batch is cheaper and simpler
- Micro-batch window so small (< 100 ms) it adds overhead without improving latency vs true streaming
- No incremental watermark on batch jobs — reprocesses the entire dataset on each run

**Python — incremental batch load with offset tracking:**
```python
from datetime import datetime, timezone
import json
from pathlib import Path

CHECKPOINT_FILE = Path("/var/pipeline/checkpoints/orders.json")

def load_checkpoint() -> datetime:
    if CHECKPOINT_FILE.exists():
        data = json.loads(CHECKPOINT_FILE.read_text())
        return datetime.fromisoformat(data["last_processed_at"])
    return datetime(2000, 1, 1, tzinfo=timezone.utc)

def save_checkpoint(ts: datetime) -> None:
    CHECKPOINT_FILE.write_text(json.dumps({"last_processed_at": ts.isoformat()}))

def incremental_batch(db_conn, warehouse_conn) -> None:
    since = load_checkpoint()
    rows = db_conn.execute(
        "SELECT * FROM orders WHERE updated_at > %s ORDER BY updated_at",
        (since,),
    ).fetchall()
    if not rows:
        return
    warehouse_conn.executemany("INSERT INTO orders VALUES (?, ?, ?)", rows)
    save_checkpoint(rows[-1]["updated_at"])
```

**Python — streaming consumer (Kafka) with micro-batch accumulation:**
```python
from kafka import KafkaConsumer
import time

MICRO_BATCH_SIZE = 500
MICRO_BATCH_WINDOW_MS = 5_000

def micro_batch_consumer(topic: str, process_batch) -> None:
    consumer = KafkaConsumer(topic, enable_auto_commit=False)
    batch: list = []
    window_start = time.monotonic()

    for message in consumer:
        batch.append(message.value)
        elapsed_ms = (time.monotonic() - window_start) * 1000
        if len(batch) >= MICRO_BATCH_SIZE or elapsed_ms >= MICRO_BATCH_WINDOW_MS:
            process_batch(batch)
            consumer.commit()  # commit after successful processing
            batch = []
            window_start = time.monotonic()
```

---

### 3. Idempotency and Exactly-Once Delivery

Exactly-once delivery is hard; idempotent consumers are the practical alternative. Design consumers so that processing the same message twice produces the same result as processing it once.

**Red Flags:**
- `INSERT INTO` without an idempotency guard — duplicate messages create duplicate rows
- Side effects (email sends, charge requests) triggered inside a retry loop with no deduplication
- Using message offset as the only identity — reprocessed partitions produce duplicates
- No idempotency key passed to payment / notification APIs

**Python — upsert guard (PostgreSQL):**
```python
def upsert_event(conn, event_id: str, payload: dict) -> None:
    """Idempotent insert — safe to call multiple times with the same event_id."""
    conn.execute(
        """
        INSERT INTO processed_events (event_id, payload, processed_at)
        VALUES (%s, %s, NOW())
        ON CONFLICT (event_id) DO NOTHING
        """,
        (event_id, json.dumps(payload)),
    )
```

**SQL — deduplicated load pattern (warehouse):**
```sql
-- Stage new rows
INSERT INTO staging.raw_orders
SELECT * FROM external_stage WHERE load_date = CURRENT_DATE;

-- Merge into target — idempotent upsert
MERGE INTO orders AS target
USING (
    SELECT DISTINCT ON (order_id) *
    FROM staging.raw_orders
    ORDER BY order_id, updated_at DESC
) AS source
ON target.order_id = source.order_id
WHEN MATCHED THEN UPDATE SET amount = source.amount, status = source.status
WHEN NOT MATCHED THEN INSERT VALUES (source.order_id, source.amount, source.status);
```

**TypeScript — idempotency key for external API calls:**
```typescript
async function chargeWithIdempotency(
  orderId: string,
  amount: number,
): Promise<ChargeResult> {
  return paymentClient.charge({
    amount,
    idempotencyKey: `order-${orderId}`,  // same key = same result, no double charge
  });
}
```

---

### 4. Watermarking, Checkpointing, and Offset Management

Watermarks define how far behind real-time a stream processor waits before closing a window. Checkpoints persist the processor's progress so it can resume without reprocessing from the beginning.

**Red Flags:**
- No watermark on event-time windows — late-arriving events silently dropped or incorrectly bucketed
- Checkpoint interval so long that recovery reprocesses hours of data
- Checkpointing after side effects (e.g., after sending an email) — re-run triggers duplicate actions
- Storing checkpoint state in memory only — lost on process restart

**Python — event-time watermark for windowed aggregation:**
```python
from collections import defaultdict
from datetime import datetime, timedelta

WATERMARK_LAG = timedelta(seconds=30)

def process_with_watermark(events: list[dict], emit_window) -> None:
    """Emit a window only when the watermark has passed its end time."""
    windows: dict[datetime, list] = defaultdict(list)

    for event in sorted(events, key=lambda e: e["event_time"]):
        event_time: datetime = event["event_time"]
        window_start = event_time.replace(second=0, microsecond=0)
        windows[window_start].append(event)

        watermark = event_time - WATERMARK_LAG
        for ws in list(windows):
            if ws + timedelta(minutes=1) <= watermark:
                emit_window(ws, windows.pop(ws))
```

**Python — durable checkpoint using file-based offset:**
```python
import json
from pathlib import Path

class KafkaCheckpoint:
    def __init__(self, path: str) -> None:
        self._path = Path(path)
        self._offsets: dict[str, int] = self._load()

    def _load(self) -> dict[str, int]:
        if self._path.exists():
            return json.loads(self._path.read_text())
        return {}

    def get(self, partition: str) -> int:
        return self._offsets.get(partition, 0)

    def commit(self, partition: str, offset: int) -> None:
        # Immutable update — write new state atomically
        new_offsets = {**self._offsets, partition: offset}
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(new_offsets))
        tmp.replace(self._path)  # atomic rename
        self._offsets = new_offsets
```

---

### 5. Dead Letter Queues (DLQ) and Error Queues

Unprocessable records must be captured, not discarded. A DLQ preserves the original message with error metadata so engineers can inspect, fix, and replay without data loss.

**Red Flags:**
- `except Exception: continue` in a message loop — records silently dropped
- DLQ exists but no alert on queue depth — failures accumulate unnoticed
- DLQ messages have no error metadata — impossible to diagnose without re-running
- No replay mechanism — DLQ is a dead end, not a recovery path
- Retry limit too high (> 5) — bad messages consume resources before being dead-lettered

**Python — DLQ producer with error metadata:**
```python
import json
import traceback
from dataclasses import dataclass, asdict
from datetime import datetime, timezone

@dataclass(frozen=True)
class DLQRecord:
    original_message: dict
    error_type: str
    error_message: str
    traceback: str
    failed_at: str
    retry_count: int

def send_to_dlq(queue_client, message: dict, exc: Exception, retry_count: int) -> None:
    record = DLQRecord(
        original_message=message,
        error_type=type(exc).__name__,
        error_message=str(exc),
        traceback=traceback.format_exc(),
        failed_at=datetime.now(timezone.utc).isoformat(),
        retry_count=retry_count,
    )
    queue_client.send(json.dumps(asdict(record)))

MAX_RETRIES = 3

def consume(queue_client, dlq_client, process_fn) -> None:
    for message, retry_count in queue_client.poll():
        try:
            process_fn(message)
            queue_client.ack(message)
        except Exception as exc:
            if retry_count >= MAX_RETRIES:
                send_to_dlq(dlq_client, message, exc, retry_count)
                queue_client.ack(message)  # remove from main queue after DLQ routing
            else:
                queue_client.nack(message)  # requeue with backoff
```

Cross-reference: `error-handling-patterns` — Dead Letter Queue section for SQS-specific implementation.

---

### 6. Backpressure and Flow Control

Backpressure is the mechanism by which a consumer signals to a producer that it cannot accept more data. Without it, fast producers overwhelm slow consumers, causing unbounded memory growth or dropped data.

**Red Flags:**
- Unbounded in-memory queue between producer and consumer — OOM under load
- Producer ignores consumer lag metrics — pushes at full speed regardless of downstream state
- No rate limiting on API-sourced ingestion — hits rate limits, causing retries that worsen the situation
- `asyncio.create_task` in a loop without a semaphore — spawns thousands of coroutines simultaneously

**Python — bounded queue with backpressure:**
```python
import asyncio

QUEUE_MAX = 200

async def producer(queue: asyncio.Queue, source) -> None:
    """Producer blocks automatically when queue is full (backpressure)."""
    async for item in source:
        await queue.put(item)  # blocks when queue reaches QUEUE_MAX

async def consumer(queue: asyncio.Queue, sink) -> None:
    while True:
        item = await queue.get()
        await sink.write(item)
        queue.task_done()

async def run_pipeline(source, sink) -> None:
    queue: asyncio.Queue = asyncio.Queue(maxsize=QUEUE_MAX)
    await asyncio.gather(producer(queue, source), consumer(queue, sink))
```

**Python — token bucket rate limiter for API ingestion:**
```python
import asyncio
import time

class TokenBucketRateLimiter:
    def __init__(self, rate: float, capacity: float) -> None:
        self._rate = rate          # tokens added per second
        self._capacity = capacity  # max tokens
        self._tokens = capacity
        self._last_refill = time.monotonic()

    async def acquire(self) -> None:
        while True:
            now = time.monotonic()
            elapsed = now - self._last_refill
            self._tokens = min(self._capacity, self._tokens + elapsed * self._rate)
            self._last_refill = now
            if self._tokens >= 1:
                self._tokens -= 1
                return
            await asyncio.sleep(1.0 / self._rate)
```

---

### 7. Schema Evolution and Data Contracts

Schema changes are the most common source of silent pipeline breakage. Data contracts make expectations explicit between producers and consumers; schema evolution rules determine which changes are safe.

**Backwards-compatible (safe) changes:**
- Adding an optional field with a default
- Adding a new enum value (only if consumers use a catch-all default)
- Widening a numeric type (INT32 → INT64)

**Breaking changes (require versioning or coordination):**
- Renaming or removing a field
- Changing a field's type (STRING → INT)
- Changing a field from optional to required

**Red Flags:**
- Schema changes deployed to producer without notifying downstream consumers
- No schema registry — JSON shape defined only in comments or tribal knowledge
- Consumers parse raw JSON with no validation — breakage is silent until data is queried
- No version field in event payloads — impossible to route to correct handler on schema change

**Python — schema validation with Pydantic (data contract):**
```python
from pydantic import BaseModel, Field, validator
from typing import Literal

class OrderEventV1(BaseModel):
    version: Literal["v1"] = "v1"
    order_id: str
    amount: float = Field(gt=0)
    currency: str = Field(min_length=3, max_length=3)
    status: Literal["pending", "confirmed", "cancelled"]

    @validator("currency")
    def currency_uppercase(cls, v: str) -> str:
        return v.upper()

def parse_event(raw: dict) -> OrderEventV1:
    """Fail fast at the pipeline boundary — never pass unvalidated data downstream."""
    return OrderEventV1(**raw)
```

**SQL — schema contract via view versioning:**
```sql
-- v1 contract: stable columns exposed to downstream consumers
CREATE OR REPLACE VIEW contracts.orders_v1 AS
SELECT order_id, amount, currency, status, created_at FROM raw.orders;

-- v2 contract: add new column without breaking v1 consumers
CREATE OR REPLACE VIEW contracts.orders_v2 AS
SELECT order_id, amount, currency, status, created_at, updated_at FROM raw.orders;
```

---

### 8. Pipeline Orchestration and DAG Design

A DAG (Directed Acyclic Graph) makes task dependencies explicit, enabling parallel execution of independent tasks, targeted retries on failure, and SLA monitoring at the task level.

**Red Flags:**
- Linear shell scripts chained with `&&` — no partial retry, no dependency visualization
- All tasks run sequentially when upstream/downstream tasks are independent
- No task-level timeout — one hung task blocks the entire DAG
- Retries configured globally with no backoff — flapping tasks hammer downstream systems
- No alerting on SLA breach — pipeline is hours late before anyone notices

**Python — Airflow-style DAG definition pattern:**
```python
from dataclasses import dataclass, field
from typing import Callable

@dataclass
class Task:
    task_id: str
    fn: Callable
    depends_on: list[str] = field(default_factory=list)
    retries: int = 3
    retry_delay_seconds: float = 30.0
    timeout_seconds: float = 3600.0

# Dependency graph is declared, not implied by execution order
extract_orders = Task("extract_orders", fn=extract_orders_fn)
extract_products = Task("extract_products", fn=extract_products_fn)
transform = Task(
    "transform",
    fn=transform_fn,
    depends_on=["extract_orders", "extract_products"],  # runs after both
)
load = Task("load", fn=load_fn, depends_on=["transform"])
```

---

## Data Pipeline Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Silent Record Drop** | `except: pass` in message loop discards failed records | Route to DLQ with error metadata; never silently discard |
| **Full Reload on Every Run** | Re-processes entire dataset because no incremental offset is tracked | Add watermark / checkpoint; load only new or changed records |
| **Transform in Application, Not Warehouse** | Python loops doing what a SQL `GROUP BY` could handle in milliseconds | Push transformation to the warehouse; use ELT |
| **Mutable Pipeline State** | Mutating shared dictionaries or lists across pipeline stages | Return new objects at each stage; use immutable dataclasses |
| **Unbounded Retry** | Retry loop with no limit and no backoff on a broken record | Enforce max retry count; route to DLQ after threshold |
| **No Schema Validation at Ingestion** | Raw JSON passed downstream without parsing or validation | Validate with Pydantic / JSON Schema at the pipeline boundary |
| **Breaking Schema Change Without Versioning** | Renaming a field breaks all consumers silently | Use additive changes; version event schemas; maintain contracts |
| **Producer Ignores Consumer Lag** | Kafka producer publishes at maximum rate; consumers fall hours behind | Monitor consumer group lag; implement backpressure or slow the producer |
| **No Idempotency on Reprocessing** | Re-running a pipeline after a failure creates duplicate rows | Use `INSERT ... ON CONFLICT DO NOTHING` or deduplicate on a natural key |
| **God Pipeline** | One 2,000-line script that extracts, transforms, enriches, and loads | Split into focused stages; each stage has a single responsibility |

**Code review signal — God Pipeline:**
```python
# Red flag: one function doing everything
def run():                          # 200+ lines
    conn = psycopg2.connect(...)
    rows = conn.execute("SELECT ...").fetchall()
    enriched = []
    for row in rows:                # inline transformation
        user = requests.get(...)    # inline enrichment
        enriched.append(...)
    conn.execute("INSERT ...")      # inline load
    send_slack_notification(...)    # side effect mixed in

# Fix: separate extraction, transformation, enrichment, and loading
def extract(conn) -> list[RawRecord]: ...
def enrich(records: list[RawRecord], api) -> list[EnrichedRecord]: ...
def transform(records: list[EnrichedRecord]) -> list[OutputRecord]: ...
def load(records: list[OutputRecord], conn) -> None: ...
```

---

## Cross-References

- `event-sourcing-cqrs-patterns` — Event log as the authoritative pipeline source; CQRS read models as pipeline outputs; event versioning strategy
- `observability-patterns` — Pipeline metrics (records processed, lag, DLQ depth); distributed tracing across pipeline stages; SLA alerting
- `error-handling-patterns` — Dead Letter Queue implementation details (SQS); retry with exponential backoff; circuit breaker on external enrichment calls
- `database-review-patterns` — Incremental load query patterns; index selection for high-volume inserts; UPSERT / MERGE semantics
- `concurrency-patterns` — Producer-consumer with bounded queues; async task pools for parallel ingestion stages
