---
name: batch-job-patterns
description: Use when designing or reviewing batch processing systems — covers distributed locking for exclusive job execution, idempotent checkpoint/resume, heartbeat-based dead job detection, job scheduling strategies, graceful shutdown, retry and DLQ for failed items, batch size optimization, and common anti-patterns across TypeScript, Go, and Python
---

# Batch Job Patterns

## Overview

Batch jobs fail in subtle ways: two instances start simultaneously and corrupt shared state, a crash at item 50,000 restarts the job from item 1, a dead worker holds a lock forever, or an unbounded batch runs out of memory. Use this guide when designing, implementing, or reviewing batch processing systems.

**When to use:** Designing scheduled jobs, ETL pipelines, bulk data migrations, report generation, queue-draining workers, or any process that operates on a bounded or streaming set of records.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Distributed Locking | Only one instance runs at a time via SETNX / advisory lock | Multiple instances starting the same job simultaneously |
| Idempotent Checkpoint/Resume | Track cursor position so a crash restarts mid-batch, not from scratch | Job restarts from item 1 on every failure |
| Heartbeat / Dead Job Detection | Worker renews a lease; expired lease means worker is dead | Lock held forever by a crashed worker |
| Job Scheduling | Cron, interval, event-triggered, or priority queue dispatch | Drift, missed runs, or runaway overlapping executions |
| Graceful Shutdown | SIGTERM drains in-flight items before exit | Partial item writes or corrupted state on deploy/restart |
| Retry and DLQ | Per-item retry with skip-or-fail policy; unprocessable items route to DLQ | Silent discard of failed items, or one bad item halts the entire batch |
| Batch Size Optimization | Memory-bounded chunks with throughput tuning | OOM crashes or 1-item-at-a-time throughput bottlenecks |

---

## Patterns in Detail

### 1. Distributed Locking for Exclusive Job Execution

Without a distributed lock, two cron nodes or scaled replicas can start the same job simultaneously — leading to duplicate processing, race conditions, and data corruption.

**Red Flags:**
- No lock before starting a batch job in a multi-instance deployment
- Lock acquired with no expiry — dead worker holds it forever
- Lock released in a non-atomic way (check-then-delete can delete another owner's lock)
- Advisory lock never checked for success before proceeding

**Redis SETNX (TypeScript):**
```typescript
// SETNX = SET if Not eXists — atomic exclusive lock
async function acquireLock(
  redis: Redis,
  lockKey: string,
  ttlMs: number,
  ownerId: string
): Promise<boolean> {
  // NX: only set if not exists; PX: expire in milliseconds
  const result = await redis.set(lockKey, ownerId, 'NX', 'PX', ttlMs);
  return result === 'OK';
}

async function releaseLock(redis: Redis, lockKey: string, ownerId: string): Promise<void> {
  // Lua script ensures atomic compare-and-delete — only release our own lock
  const script = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end
  `;
  await redis.eval(script, 1, lockKey, ownerId);
}

async function runExclusiveJob(redis: Redis, jobFn: () => Promise<void>): Promise<void> {
  const ownerId = crypto.randomUUID();
  const lockKey = 'job:nightly-report:lock';
  const acquired = await acquireLock(redis, lockKey, 60_000, ownerId);
  if (!acquired) {
    logger.info('Job already running on another instance — skipping');
    return;
  }
  try {
    await jobFn();
  } finally {
    await releaseLock(redis, lockKey, ownerId);
  }
}
```

**PostgreSQL Advisory Lock (Go):**
```go
// Advisory locks are session-scoped and auto-released on connection close
func acquireAdvisoryLock(db *sql.DB, lockID int64) (bool, error) {
    var acquired bool
    err := db.QueryRow("SELECT pg_try_advisory_lock($1)", lockID).Scan(&acquired)
    return acquired, err
}

func runExclusiveJob(db *sql.DB, jobFn func() error) error {
    const lockID = 123456789 // unique per job type — use a constant registry
    acquired, err := acquireAdvisoryLock(db, lockID)
    if err != nil {
        return fmt.Errorf("acquireAdvisoryLock: %w", err)
    }
    if !acquired {
        log.Println("job already running — skipping")
        return nil
    }
    defer db.Exec("SELECT pg_advisory_unlock($1)", lockID)
    return jobFn()
}
```

---

### 2. Idempotent Checkpoint / Resume Pattern

A job that processes 1M records and crashes at record 750,000 should resume at 750,000 — not restart from 1. Checkpoints also enable idempotency: replaying the job produces the same result.

**Red Flags:**
- No cursor or offset stored between batches — job always starts from the beginning
- Checkpoint written inside a transaction that also modifies business data, but not atomically
- Resuming without verifying checkpoint integrity (stale or corrupt checkpoint)
- Processing without idempotency keys — duplicate processing on retry

**Python (cursor-based pagination with checkpoint):**
```python
import json, time
from pathlib import Path

CHECKPOINT_FILE = Path("/var/run/jobs/user-sync.checkpoint.json")

def load_checkpoint() -> dict:
    if CHECKPOINT_FILE.exists():
        return json.loads(CHECKPOINT_FILE.read_text())
    return {"last_id": 0, "processed": 0}

def save_checkpoint(state: dict) -> None:
    # Atomic write: write to temp, then rename — prevents partial writes
    tmp = CHECKPOINT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    tmp.rename(CHECKPOINT_FILE)

def run_user_sync(db, batch_size: int = 500) -> None:
    state = load_checkpoint()
    last_id = state["last_id"]
    total = state["processed"]

    while True:
        rows = db.query(
            "SELECT id, email FROM users WHERE id > %s ORDER BY id LIMIT %s",
            (last_id, batch_size)
        )
        if not rows:
            break

        for row in rows:
            sync_user_to_crm(row)  # idempotent — CRM upserts by email

        last_id = rows[-1]["id"]
        total += len(rows)
        save_checkpoint({"last_id": last_id, "processed": total})

    CHECKPOINT_FILE.unlink(missing_ok=True)  # clean up on success
```

**TypeScript (database-persisted checkpoint):**
```typescript
interface JobCheckpoint {
  jobId: string;
  cursor: string;
  processedCount: number;
  updatedAt: Date;
}

async function upsertCheckpoint(db: Db, checkpoint: JobCheckpoint): Promise<void> {
  await db.query(
    `INSERT INTO job_checkpoints (job_id, cursor, processed_count, updated_at)
     VALUES ($1, $2, $3, NOW())
     ON CONFLICT (job_id) DO UPDATE
     SET cursor = $2, processed_count = $3, updated_at = NOW()`,
    [checkpoint.jobId, checkpoint.cursor, checkpoint.processedCount]
  );
}

async function resumableBatch(db: Db, jobId: string): Promise<void> {
  const saved = await db.query<JobCheckpoint>(
    'SELECT * FROM job_checkpoints WHERE job_id = $1', [jobId]
  );
  let cursor = saved.rows[0]?.cursor ?? '';
  let processed = saved.rows[0]?.processedCount ?? 0;

  while (true) {
    const items = await fetchPage(db, cursor, 500);
    if (items.length === 0) break;

    await processBatch(items);

    cursor = items[items.length - 1].id;
    processed += items.length;
    await upsertCheckpoint(db, { jobId, cursor, processedCount: processed, updatedAt: new Date() });
  }
}
```

---

### 3. Heartbeat-Based Dead Job Detection

A worker acquires a lock, then crashes before releasing it. Without a heartbeat mechanism, the lock is held until TTL expires — which may be hours. Heartbeats allow detecting dead workers in seconds.

**Red Flags:**
- Lock TTL set to job duration — no renewal means lock expires mid-run
- No heartbeat thread — crashed worker's lock persists until TTL
- Heartbeat failure not treated as a fatal error — job continues without a valid lease
- Lease renewal racing with job completion

**Go (heartbeat goroutine with lease renewal):**
```go
type Lease struct {
    redis    *redis.Client
    key      string
    ownerID  string
    ttl      time.Duration
    stopCh   chan struct{}
    doneCh   chan struct{}
}

func NewLease(redis *redis.Client, key, ownerID string, ttl time.Duration) *Lease {
    return &Lease{redis: redis, key: key, ownerID: ownerID, ttl: ttl,
        stopCh: make(chan struct{}), doneCh: make(chan struct{})}
}

// StartHeartbeat renews the lease at ttl/2 interval
func (l *Lease) StartHeartbeat(ctx context.Context) {
    go func() {
        defer close(l.doneCh)
        ticker := time.NewTicker(l.ttl / 2)
        defer ticker.Stop()
        for {
            select {
            case <-ticker.C:
                // EXPIRE resets TTL; only renew if we still own the key
                script := `
                    if redis.call("get", KEYS[1]) == ARGV[1] then
                        return redis.call("pexpire", KEYS[1], ARGV[2])
                    else
                        return 0
                    end`
                result, err := l.redis.Eval(ctx, script, []string{l.key},
                    l.ownerID, l.ttl.Milliseconds()).Int()
                if err != nil || result == 0 {
                    log.Printf("lease lost for %s — stopping heartbeat", l.key)
                    return
                }
            case <-l.stopCh:
                return
            }
        }
    }()
}

func (l *Lease) Stop() { close(l.stopCh); <-l.doneCh }
```

**Timeout-based dead job detection (Python):**
```python
HEARTBEAT_KEY = "job:{job_id}:heartbeat"
HEARTBEAT_INTERVAL = 10  # seconds
DEAD_THRESHOLD = 30      # seconds without heartbeat → job is dead

def is_job_dead(redis_client, job_id: str) -> bool:
    last_beat = redis_client.get(HEARTBEAT_KEY.format(job_id=job_id))
    if last_beat is None:
        return True
    elapsed = time.time() - float(last_beat)
    return elapsed > DEAD_THRESHOLD

def claim_dead_job(redis_client, job_id: str) -> bool:
    """Claim a stalled job for reprocessing."""
    if not is_job_dead(redis_client, job_id):
        return False
    # Atomic: only one claimer wins the SETNX race
    return redis_client.set(
        f"job:{job_id}:lock", "new-owner", nx=True, ex=60
    )
```

---

### 4. Job Scheduling Strategies

Batch jobs run on a schedule (cron), at fixed intervals, in response to events, or via a priority queue. Choosing the wrong strategy causes drift, missed runs, or starvation.

**Red Flags:**
- Cron with no overlap protection — previous run still active when next fires
- Interval timer restarts immediately after failure — no backoff
- Event-triggered jobs with no deduplication — fan-out storms on burst events
- Priority queues where low-priority items starve indefinitely

**Scheduling strategy comparison:**

| Strategy | When to Use | Key Risk | Mitigation |
|----------|------------|----------|-----------|
| Cron | Fixed wall-clock schedule | Overlap if job > interval | Distributed lock + skip-if-running |
| Interval | Run N seconds after last completion | Drift under load | Track completion time, not start time |
| Event-triggered | React to upstream data arrival | Duplicate events, fan-out storms | Idempotency key + debounce window |
| Priority queue | Mixed urgency workloads | Low-priority starvation | Aging: boost priority after wait threshold |

**TypeScript (cron with overlap guard):**
```typescript
import { CronJob } from 'cron';

let running = false;

const job = new CronJob('0 2 * * *', async () => {  // 02:00 daily
  if (running) {
    logger.warn('Previous run still active — skipping this tick');
    return;
  }
  running = true;
  try {
    await runNightlyReport();
  } catch (err) {
    logger.error('Nightly report failed', { err });
    metrics.increment('batch.nightly_report.failure');
  } finally {
    running = false;
  }
});
```

**Go (priority queue with aging):**
```go
type JobItem struct {
    ID        string
    Priority  int
    EnqueuedAt time.Time
}

// Age items: boost priority by 1 for each 5 minutes of wait
func effectivePriority(item JobItem) int {
    ageMinutes := int(time.Since(item.EnqueuedAt).Minutes())
    return item.Priority + ageMinutes/5
}
```

---

### 5. Graceful Shutdown During Batch Runs

Deploying or scaling down while a batch is running can leave items in a half-processed state. SIGTERM handling with a drain period ensures the current item finishes before the process exits.

**Red Flags:**
- `process.exit()` called immediately on SIGTERM — in-flight items are abandoned
- No drain timeout — a misbehaving item can prevent shutdown indefinitely
- Database transaction open at shutdown — connection closed mid-transaction causes partial writes
- Checkpoint not saved before exit — resume restarts from last checkpoint, not current cursor

**TypeScript (SIGTERM with drain):**
```typescript
let shuttingDown = false;

process.on('SIGTERM', () => {
  logger.info('SIGTERM received — draining current batch item');
  shuttingDown = true;
  // Force exit after drain period regardless
  setTimeout(() => {
    logger.error('Drain timeout exceeded — forcing exit');
    process.exit(1);
  }, 30_000).unref();
});

async function processBatchLoop(items: AsyncIterable<Item>): Promise<void> {
  for await (const item of items) {
    if (shuttingDown) {
      logger.info('Shutdown flag set — stopping batch loop cleanly');
      break;
    }
    await processItem(item);
    await saveCheckpoint(item.id);
  }
}
```

**Go (context cancellation on SIGTERM):**
```go
func main() {
    ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
    defer stop()

    if err := runBatch(ctx); err != nil && !errors.Is(err, context.Canceled) {
        log.Fatalf("batch failed: %v", err)
    }
    log.Println("batch completed or drained gracefully")
}

func runBatch(ctx context.Context) error {
    for {
        select {
        case <-ctx.Done():
            log.Println("context cancelled — saving checkpoint and exiting")
            return saveCheckpoint()
        default:
        }

        item, err := fetchNextItem(ctx)
        if errors.Is(err, io.EOF) {
            return nil // batch complete
        }
        if err != nil {
            return fmt.Errorf("fetchNextItem: %w", err)
        }
        if err := processItem(ctx, item); err != nil {
            return fmt.Errorf("processItem %s: %w", item.ID, err)
        }
    }
}
```

---

### 6. Retry and Error Handling for Batch Items

A single corrupt record should not halt the entire job. A transient network error should be retried. Retry and DLQ strategies decouple item-level failures from job-level failures.

**Red Flags:**
- One failed item causes `panic` or unrecovered error that stops the whole batch
- All errors retried — including permanent errors like schema validation failures
- No retry limit — transient errors loop forever
- Failed items silently skipped — no DLQ, no audit trail
- DLQ exists but is never monitored or replayed

**Python (per-item retry with DLQ routing):**
```python
import time, json
from dataclasses import dataclass
from typing import Callable

@dataclass
class BatchResult:
    processed: int = 0
    failed: int = 0
    skipped: int = 0

def is_retryable(err: Exception) -> bool:
    return isinstance(err, (ConnectionError, TimeoutError))

def process_with_retry(
    item: dict,
    handler: Callable,
    dlq_writer,
    max_attempts: int = 3,
    base_delay: float = 0.5
) -> str:
    """Returns 'ok', 'skipped', or 'dlq'."""
    last_err = None
    for attempt in range(1, max_attempts + 1):
        try:
            handler(item)
            return 'ok'
        except Exception as err:
            last_err = err
            if not is_retryable(err):
                break  # permanent failure — skip to DLQ immediately
            if attempt < max_attempts:
                time.sleep(base_delay * 2 ** (attempt - 1))

    dlq_writer.send(json.dumps({
        "item": item,
        "error": str(last_err),
        "timestamp": time.time()
    }))
    return 'dlq'

def run_batch(items, handler, dlq_writer) -> BatchResult:
    result = BatchResult()
    for item in items:
        outcome = process_with_retry(item, handler, dlq_writer)
        if outcome == 'ok':
            result.processed += 1
        else:
            result.failed += 1
    return result
```

**TypeScript (fail-all vs skip policy):**
```typescript
type ItemPolicy = 'skip-on-error' | 'fail-all';

async function processBatch(
  items: Item[],
  handler: (item: Item) => Promise<void>,
  policy: ItemPolicy = 'skip-on-error',
  dlq: DLQClient
): Promise<void> {
  const errors: Array<{ item: Item; err: unknown }> = [];

  for (const item of items) {
    try {
      await handler(item);
    } catch (err) {
      if (policy === 'fail-all') throw err; // abort entire batch
      logger.warn('Item failed — routing to DLQ', { itemId: item.id, err });
      await dlq.send({ item, error: String(err), ts: new Date().toISOString() });
      errors.push({ item, err });
    }
  }

  if (errors.length > 0) {
    logger.error(`Batch completed with ${errors.length} item failures routed to DLQ`);
    metrics.gauge('batch.dlq_routed', errors.length);
  }
}
```

Cross-reference: `error-handling-patterns` — Dead Letter Queue for DLQ monitoring and replay patterns.

---

### 7. Batch Size Optimization

Too small: context-switch overhead dominates throughput. Too large: OOM crash or lock contention. Optimal batch size is bounded by memory and tuned for throughput.

**Red Flags:**
- Batch size hardcoded to 1 — N round-trips instead of 1 bulk insert
- Batch size unbounded — `SELECT * FROM table` loads all rows into memory
- No memory accounting — batch size set by row count, not by actual byte footprint
- No throughput metrics — batch size never tuned based on observed performance

**Memory-bounded batching (Go):**
```go
const (
    MaxBatchBytes = 64 * 1024 * 1024 // 64 MB cap per batch
    MinBatchSize  = 10
    MaxBatchSize  = 5_000
)

func memoryBoundedBatch(rows []Row, estimateSize func(Row) int) [][]Row {
    var batches [][]Row
    var current []Row
    var currentBytes int

    for _, row := range rows {
        rowBytes := estimateSize(row)
        if len(current) >= MinBatchSize &&
            (currentBytes+rowBytes > MaxBatchBytes || len(current) >= MaxBatchSize) {
            batches = append(batches, current)
            current = nil
            currentBytes = 0
        }
        current = append(current, row)
        currentBytes += rowBytes
    }
    if len(current) > 0 {
        batches = append(batches, current)
    }
    return batches
}
```

**Throughput tuning with adaptive batch size (Python):**
```python
import time

class AdaptiveBatcher:
    """Adjusts batch size based on observed throughput."""

    def __init__(self, initial_size: int = 100, min_size: int = 10, max_size: int = 2000):
        self.size = initial_size
        self.min_size = min_size
        self.max_size = max_size
        self._last_throughput: float | None = None

    def record(self, items_processed: int, elapsed_s: float) -> None:
        throughput = items_processed / elapsed_s if elapsed_s > 0 else 0
        if self._last_throughput is not None:
            if throughput > self._last_throughput * 1.1:
                self.size = min(int(self.size * 1.25), self.max_size)
            elif throughput < self._last_throughput * 0.9:
                self.size = max(int(self.size * 0.75), self.min_size)
        self._last_throughput = throughput

    def run(self, fetch_fn, process_fn) -> None:
        while True:
            t0 = time.monotonic()
            items = fetch_fn(self.size)
            if not items:
                break
            process_fn(items)
            self.record(len(items), time.monotonic() - t0)
```

---

### 8. Batch Job Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **No Distributed Lock** | Multiple instances run the same job simultaneously | Acquire Redis SETNX or advisory lock before starting |
| **No Idempotency** | Retrying the job after partial failure re-processes already-done items | Use cursor-based checkpoints; make each item operation idempotent |
| **Unbounded Batch** | `SELECT * FROM table` loads entire dataset into memory | Use cursor pagination with a memory-bounded page size |
| **No Progress Tracking** | Job runs for hours with no visibility into progress | Write checkpoint after each page; emit metrics per batch |
| **Fail-All on Item Error** | One corrupt row aborts the entire multi-hour job | Use skip-on-error policy with DLQ routing for failed items |
| **No Heartbeat** | Crashed worker holds the lock until TTL expires | Renew lease every TTL/2; monitor heartbeat lag |
| **No Graceful Shutdown** | SIGTERM mid-batch leaves half-written records | Check shutdown flag before each item; save checkpoint on exit |
| **Retry Without Backoff** | Transient failure retried immediately in a tight loop | Exponential backoff with jitter between retry attempts |

**No distributed lock — TypeScript fix:**
```typescript
// WRONG: job starts immediately without checking for concurrent instances
async function runJob() { await processAllUsers(); }

// CORRECT: acquire exclusive lock before starting
async function runJob(redis: Redis) {
  const acquired = await acquireLock(redis, 'job:process-users:lock', 120_000, crypto.randomUUID());
  if (!acquired) { logger.info('Already running — skipping'); return; }
  // ... run job, release lock in finally
}
```

**Unbounded batch — Go fix:**
```go
// WRONG: loads entire table into memory
// rows, _ := db.Query("SELECT * FROM orders")

// CORRECT: cursor pagination
func processOrders(db *sql.DB) error {
    var lastID int64
    for {
        rows, err := db.Query(
            "SELECT id, data FROM orders WHERE id > $1 ORDER BY id LIMIT 500",
            lastID,
        )
        if err != nil { return fmt.Errorf("query: %w", err) }
        count := 0
        for rows.Next() {
            var o Order
            rows.Scan(&o.ID, &o.Data)
            processOrder(o)
            lastID = o.ID
            count++
        }
        rows.Close()
        if count == 0 { break }
    }
    return nil
}
```

---

## Cross-References

- `data-pipeline-patterns` — Streaming vs. batch pipeline design, watermarks, and late-arriving data
- `concurrency-patterns` — Worker pools, backpressure, and bounded parallelism for parallel batch processing
- `message-queue-patterns` — Queue-backed batch dispatch, consumer group coordination, and DLQ configuration
- `error-handling-patterns` — Dead Letter Queue monitoring, per-item retry policies, and circuit breakers for external calls
- `observability-patterns` — Progress metrics, batch duration histograms, and alerting on stalled jobs
