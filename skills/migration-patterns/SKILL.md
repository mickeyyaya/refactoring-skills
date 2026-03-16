---
name: migration-patterns
description: Use when planning or reviewing monolith decomposition, service extraction, or database migration — covers Strangler Fig, Anti-Corruption Layer, Branch by Abstraction, Database Decomposition (Expand-Contract, dual-write), Change Data Capture (Debezium, AWS DMS), and migration anti-patterns across TypeScript, Go, and Java
---

# Migration Patterns

## Overview

Migrating a monolith to services, or moving a legacy database to a new schema, is one of the highest-risk engineering activities. Done wrong it causes data loss, extended downtime, and introduces coupling that is worse than the monolith it replaced. The patterns here provide incremental, reversible migration paths — each one shifts traffic or data gradually, allowing rollback at any step.

**When to use:** Planning service extraction from a monolith; replacing a legacy component; migrating databases without downtime; reviewing a migration PR for hidden risks.

## Quick Reference

| Pattern | Core Idea | When to Use |
|---------|-----------|-------------|
| Strangler Fig | Proxy routes traffic; new service replaces old routes incrementally | Extracting services from a running monolith |
| Anti-Corruption Layer | Adapter translates between old and new domain models | Integrating two bounded contexts with conflicting models |
| Branch by Abstraction | Abstract interface first, swap implementation behind it | Replacing an internal library or module in-place |
| Expand-Contract | Widen schema before migrating data, narrow after | Database column renames, type changes, normalisation |
| Dual-Write | Write to both old and new stores in parallel | Migrating a live database with zero downtime |
| CDC Bridge | Capture database change events and replay to new store | Backfilling a new service's datastore from a legacy DB |
| Change Data Capture | Stream row-level changes via Debezium or AWS DMS | Event-driven migration, read-model population |

---

## Patterns in Detail

### 1. Strangler Fig

The Strangler Fig pattern (named after the tree that grows around a host) routes all traffic through a proxy. New functionality is built in the new service; the proxy redirects matching routes there. The monolith shrinks as routes migrate until it can be deleted.

**Key phases:**
1. Deploy a routing proxy in front of the monolith (no traffic change yet)
2. Build the replacement service endpoint
3. Shadow-test: send traffic to both, compare responses, route users to new service
4. Remove the monolith code path when confidence is high

**Red Flags:**
- New service writes directly to the monolith database — tight coupling survives the migration
- No proxy layer — cutover is a big-bang deployment
- Migrating all routes at once — increases blast radius if something is wrong
- No feature flag or percentage rollout — impossible to roll back without a deploy

**TypeScript — Express proxy with route-level cutover:**
```typescript
import express, { Request, Response, NextFunction } from 'express';
import httpProxy from 'http-proxy-middleware';

const FEATURE_FLAGS: Record<string, boolean> = {
  'orders-service': process.env.FF_ORDERS === 'true',
  'inventory-service': process.env.FF_INVENTORY === 'true',
};

const monolithProxy = httpProxy.createProxyMiddleware({
  target: process.env.MONOLITH_URL,
  changeOrigin: true,
});

const ordersProxy = httpProxy.createProxyMiddleware({
  target: process.env.ORDERS_SERVICE_URL,
  changeOrigin: true,
});

const router = express.Router();

// Gradually cut over /orders to the new service via feature flag
router.use('/orders', (req: Request, res: Response, next: NextFunction) => {
  if (FEATURE_FLAGS['orders-service']) {
    return ordersProxy(req, res, next);
  }
  return monolithProxy(req, res, next);
});

// Everything else stays on the monolith
router.use('/', monolithProxy);
```

**Go — percentage-based traffic split:**
```go
package proxy

import (
    "math/rand"
    "net/http"
    "net/http/httputil"
    "net/url"
)

type StranglerProxy struct {
    monolith    *httputil.ReverseProxy
    newService  *httputil.ReverseProxy
    routeWeight map[string]int // percent traffic to new service per route
}

func (p *StranglerProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    weight, ok := p.routeWeight[r.URL.Path]
    if ok && rand.Intn(100) < weight {
        p.newService.ServeHTTP(w, r)
        return
    }
    p.monolith.ServeHTTP(w, r)
}

func NewStranglerProxy(monolithURL, newServiceURL string, weights map[string]int) *StranglerProxy {
    mURL, _ := url.Parse(monolithURL)
    nURL, _ := url.Parse(newServiceURL)
    return &StranglerProxy{
        monolith:    httputil.NewSingleHostReverseProxy(mURL),
        newService:  httputil.NewSingleHostReverseProxy(nURL),
        routeWeight: weights,
    }
}
```

Cross-reference: `microservices-resilience-patterns` — Circuit Breaker pattern on the proxy to handle new-service failures during cutover.

---

### 2. Anti-Corruption Layer

Two bounded contexts rarely share the same domain model. Forcing the new service to speak the legacy model's language embeds the corruption permanently. The Anti-Corruption Layer (ACL) is an adapter that translates concepts on the boundary — the new service sees only its own clean model.

**Key responsibilities of an ACL:**
- Model translation (legacy `CustomerRecord` → new `User` domain object)
- Protocol translation (SOAP → REST, CSV export → typed DTO)
- Vocabulary translation (legacy `CUST_STATUS = 'A'` → `UserStatus.Active`)

**Red Flags:**
- New service imports legacy data types directly — bounded context leaks
- ACL mixes translation logic with business logic — hard to update when legacy schema changes
- No ACL at all — new service inherits legacy naming, status codes, and field shapes
- ACL tests missing — translation bugs are invisible until production

**TypeScript — translating a legacy order record:**
```typescript
// Legacy model (monolith database shape)
interface LegacyOrderRecord {
  ord_id: string;
  cust_no: string;
  ord_stat: 'P' | 'S' | 'C' | 'X';   // Pending, Shipped, Complete, Cancelled
  tot_amt: number;                      // cents, integer
  ord_dt: string;                       // 'YYYYMMDD'
}

// New bounded context model
interface Order {
  id: string;
  customerId: string;
  status: 'pending' | 'shipped' | 'completed' | 'cancelled';
  totalAmountCents: number;
  orderedAt: Date;
}

// Anti-Corruption Layer
const STATUS_MAP: Record<LegacyOrderRecord['ord_stat'], Order['status']> = {
  P: 'pending',
  S: 'shipped',
  C: 'completed',
  X: 'cancelled',
};

function translateOrder(legacy: LegacyOrderRecord): Order {
  return {
    id: legacy.ord_id,
    customerId: legacy.cust_no,
    status: STATUS_MAP[legacy.ord_stat],
    totalAmountCents: legacy.tot_amt,
    orderedAt: new Date(
      `${legacy.ord_dt.slice(0, 4)}-${legacy.ord_dt.slice(4, 6)}-${legacy.ord_dt.slice(6, 8)}`
    ),
  };
}
```

**Java — ACL as a dedicated service layer:**
```java
@Component
public class LegacyOrderAntiCorruptionLayer {

    private final LegacyOrderRepository legacyRepo;

    public LegacyOrderAntiCorruptionLayer(LegacyOrderRepository legacyRepo) {
        this.legacyRepo = legacyRepo;
    }

    public Order translateAndFetch(String orderId) {
        LegacyOrderRecord record = legacyRepo.findByOrdId(orderId)
            .orElseThrow(() -> new OrderNotFoundException(orderId));
        return translate(record);
    }

    private Order translate(LegacyOrderRecord record) {
        return Order.builder()
            .id(record.getOrdId())
            .customerId(record.getCustNo())
            .status(mapStatus(record.getOrdStat()))
            .totalAmountCents(record.getTotAmt())
            .orderedAt(LocalDate.parse(record.getOrdDt(),
                DateTimeFormatter.BASIC_ISO_DATE).atStartOfDay())
            .build();
    }

    private OrderStatus mapStatus(String legacyStatus) {
        return switch (legacyStatus) {
            case "P" -> OrderStatus.PENDING;
            case "S" -> OrderStatus.SHIPPED;
            case "C" -> OrderStatus.COMPLETED;
            case "X" -> OrderStatus.CANCELLED;
            default -> throw new IllegalArgumentException("Unknown status: " + legacyStatus);
        };
    }
}
```

Cross-reference: `domain-driven-design-patterns` — Bounded Context mapping and Context Map patterns.

---

### 3. Branch by Abstraction

When replacing an internal component (a library, a module, a data access layer) that is called from many places, big-bang replacement is risky. Branch by Abstraction introduces an interface first, moves all callers to the interface, then swaps the implementation — the migration is invisible to callers.

**Key phases:**
1. Extract an interface over the existing implementation
2. Update all callers to depend on the interface (not the concrete class)
3. Build the new implementation behind the interface
4. Run both implementations in parallel with verification (optional)
5. Switch the wiring to the new implementation; delete the old one

**Red Flags:**
- Replacing the implementation before abstracting callers — still a big-bang swap
- Interface designed around the old implementation's quirks — new implementation inherits debt
- No parallel verification step — regression only discovered in production
- Skipping the deletion step — dead code remains, future engineers must guess which path is live

**TypeScript — interface-first replacement of a storage adapter:**
```typescript
// Step 1: Define the abstraction
interface UserRepository {
  findById(id: string): Promise<User | null>;
  save(user: User): Promise<void>;
  delete(id: string): Promise<void>;
}

// Step 2: Wrap the legacy implementation
class LegacyUserRepository implements UserRepository {
  async findById(id: string): Promise<User | null> {
    return legacyDb.query(`SELECT * FROM users WHERE id = ?`, [id]);
  }
  async save(user: User): Promise<void> {
    await legacyDb.execute(`INSERT INTO users ...`);
  }
  async delete(id: string): Promise<void> {
    await legacyDb.execute(`DELETE FROM users WHERE id = ?`, [id]);
  }
}

// Step 3: New implementation (Postgres + TypeORM)
class PostgresUserRepository implements UserRepository {
  constructor(private readonly orm: DataSource) {}
  async findById(id: string): Promise<User | null> {
    return this.orm.getRepository(UserEntity).findOneBy({ id });
  }
  async save(user: User): Promise<void> {
    await this.orm.getRepository(UserEntity).save(toEntity(user));
  }
  async delete(id: string): Promise<void> {
    await this.orm.getRepository(UserEntity).delete(id);
  }
}

// Step 4 (optional): Verification shim — reads from new, falls back to legacy, alerts on divergence
class VerifyingUserRepository implements UserRepository {
  constructor(
    private readonly primary: UserRepository,
    private readonly shadow: UserRepository,
    private readonly metrics: MetricsClient
  ) {}

  async findById(id: string): Promise<User | null> {
    const [primaryResult, shadowResult] = await Promise.allSettled([
      this.primary.findById(id),
      this.shadow.findById(id),
    ]);
    if (primaryResult.status === 'fulfilled' && shadowResult.status === 'fulfilled') {
      if (JSON.stringify(primaryResult.value) !== JSON.stringify(shadowResult.value)) {
        this.metrics.increment('repo.divergence', { method: 'findById' });
      }
    }
    if (primaryResult.status === 'fulfilled') return primaryResult.value;
    throw (primaryResult as PromiseRejectedResult).reason;
  }

  async save(user: User): Promise<void> { return this.primary.save(user); }
  async delete(id: string): Promise<void> { return this.primary.delete(id); }
}
```

Cross-reference: `design-patterns-behavioral` — Strategy pattern for runtime implementation swapping.

---

### 4. Database Decomposition: Expand-Contract

Renaming a column, changing a data type, or splitting a table while the application is live requires a three-phase approach to avoid downtime.

**Phases:**
1. **Expand** — Add the new column/table; write to BOTH old and new. Old reads still work.
2. **Migrate** — Backfill existing rows from old column to new column. Verify parity.
3. **Contract** — Switch reads to the new column. Remove writes to the old column. Drop the old column.

**Red Flags:**
- Dropping old column before migrating all readers — runtime errors in unreleased consumers
- No backfill verification step — silent data loss
- Executing all three phases in a single deployment — negates the safety of the pattern
- No rollback script for each phase

**Dual-Write during Expand phase (TypeScript):**
```typescript
interface OrderRow {
  id: string;
  // Expand phase: both columns present
  customer_id?: string;       // old column (being retired)
  customer_uuid?: string;     // new column (UUID format)
}

async function saveOrder(order: Order, db: DbClient): Promise<void> {
  await db.execute(
    `UPDATE orders
     SET customer_id   = $1,   -- old column: keep writing during expand phase
         customer_uuid = $2    -- new column: write from day one of expand
     WHERE id = $3`,
    [order.customerId, order.customerUuid, order.id]
  );
}

// After backfill + verification: stop writing customer_id, read customer_uuid only
async function saveOrderContracted(order: Order, db: DbClient): Promise<void> {
  await db.execute(
    `UPDATE orders SET customer_uuid = $1 WHERE id = $2`,
    [order.customerUuid, order.id]
  );
}
```

**Go — backfill with batching to avoid table locks:**
```go
func BackfillCustomerUUID(db *sql.DB) error {
    const batchSize = 500
    for {
        result, err := db.Exec(`
            UPDATE orders
            SET customer_uuid = gen_random_uuid()
            WHERE customer_uuid IS NULL
            LIMIT $1`, batchSize)
        if err != nil {
            return fmt.Errorf("backfill: %w", err)
        }
        n, _ := result.RowsAffected()
        if n == 0 {
            return nil // backfill complete
        }
        time.Sleep(50 * time.Millisecond) // yield between batches
    }
}
```

Cross-reference: `database-review-patterns` — Schema migration safety checklist.

---

### 5. Change Data Capture and CDC Bridge

Change Data Capture (CDC) reads the database transaction log (WAL in Postgres, binlog in MySQL) and emits a stream of row-level events. This enables the new service to maintain its own datastore without the application writing to two places.

**Debezium (Kafka Connect) — key concepts:**
- Source connector reads the DB log; no application code change needed
- Publishes INSERT / UPDATE / DELETE events to Kafka topics
- New service consumes the topic and applies changes to its own store
- Offset tracking ensures exactly-once processing with idempotent consumers

**AWS DMS patterns:**
- Full-load task: one-time snapshot of the source table into the target
- CDC task: continuous replication after full load completes
- Validation task: row-count and data-type checks between source and target
- Use `STOP_TASK_CACHED_CHANGES` mode to pause without data loss during cutovers

**Red Flags:**
- No idempotency key on CDC consumer — replays cause duplicates
- CDC lag not monitored — consumer falls behind, cutover window is unknown
- DDL changes (ALTER TABLE) not handled — Debezium schema registry must be updated
- CDC task started before full-load verification — incremental events applied to incomplete base data

**TypeScript — idempotent Debezium event consumer:**
```typescript
interface DebeziumOrderEvent {
  op: 'c' | 'u' | 'd' | 'r';  // create, update, delete, read (snapshot)
  before: LegacyOrderRecord | null;
  after: LegacyOrderRecord | null;
  source: { lsn: string; ts_ms: number };
}

async function handleOrderCDCEvent(
  event: DebeziumOrderEvent,
  repo: OrderRepository,
  acl: LegacyOrderAntiCorruptionLayer
): Promise<void> {
  switch (event.op) {
    case 'c':
    case 'r':
    case 'u': {
      if (!event.after) return;
      const order = acl.translate(event.after);
      // upsert is idempotent — safe to replay
      await repo.upsert(order);
      break;
    }
    case 'd': {
      if (!event.before) return;
      await repo.delete(event.before.ord_id);
      break;
    }
  }
}
```

**Java — Spring Kafka CDC consumer with idempotency guard:**
```java
@KafkaListener(topics = "dbserver1.public.orders", groupId = "orders-migration")
public void consume(ConsumerRecord<String, DebeziumOrderEvent> record) {
    DebeziumOrderEvent event = record.value();
    String eventKey = record.topic() + ":" + record.partition() + ":" + record.offset();

    if (processedEventStore.exists(eventKey)) {
        log.debug("Skipping already-processed event: {}", eventKey);
        return;
    }

    switch (event.getOp()) {
        case "c", "u", "r" -> orderRepository.upsert(acl.translate(event.getAfter()));
        case "d"            -> orderRepository.delete(event.getBefore().getOrdId());
    }
    processedEventStore.mark(eventKey);
}
```

Cross-reference: `event-sourcing-cqrs-patterns` — event replay and idempotent projection rebuilding.
Cross-reference: `message-queue-patterns` — consumer group lag monitoring and backpressure.

---

### 6. Migration Execution Checklist

Use this checklist before and during any migration:

**Pre-migration:**
- [ ] Feature flag or percentage rollout gate is in place
- [ ] Rollback procedure documented and tested in staging
- [ ] CDC lag or dual-write divergence monitoring is active
- [ ] All three Expand-Contract phases are separate deployments
- [ ] Load test the new service at production traffic levels

**During migration:**
- [ ] Monitor error rates on both old and new paths
- [ ] Verify row counts and checksums match between old and new stores
- [ ] Gradually increase traffic (1% → 10% → 50% → 100%)
- [ ] Keep the old code path live for at least one release cycle after full cutover

**Post-migration:**
- [ ] Delete the old code path and schema (avoid dead code)
- [ ] Remove the proxy/ACL once no traffic flows through it
- [ ] Archive or drop deprecated tables after retention period

---

### 7. Migration Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Shared Database with Cross-Service FK** | New service references rows in the monolith DB via foreign key — tight schema coupling survives the migration | Each service owns its data; sync via events or ACL, never FK across service boundaries |
| **Big-Bang Rewrite** | Entire system rewritten and deployed in one release — no incremental validation, catastrophic blast radius | Use Strangler Fig for incremental cutover; big-bang rewrites have a near-100% failure rate for non-trivial systems |
| **No Routing Layer** | New service deployed but DNS or load balancer switches all traffic at once | Deploy proxy first; route by feature flag or percentage; never DNS-flip without a proxy in between |
| **Dual-Write Without Verification** | Writing to both stores but never comparing them — drift goes undetected | Run a divergence checker; alert on mismatches; never trust dual-write without active reconciliation |
| **Migration Without Backfill** | New service starts capturing events from today but has no historical data | Full-load snapshot (CDC full-load task or batch backfill) before starting incremental sync |
| **Skipping the Contract Phase** | Old schema columns left indefinitely after migration — "temporary" technical debt becomes permanent | Schedule and enforce the Contract phase; block release if schema cleanup is not done within N cycles |
| **ACL-less Integration** | New service imports legacy data types or calls legacy service APIs directly | Always introduce an ACL at every bounded context boundary; never import across context lines |

**Shared database anti-pattern — TypeScript:**
```typescript
// WRONG: Orders service uses a FK into the monolith's customers table
// This means orders-service cannot deploy independently of the monolith schema
const order = await db.query(`
  SELECT o.*, c.name
  FROM orders o
  JOIN monolith.customers c ON c.id = o.customer_id   -- cross-service FK
  WHERE o.id = $1
`, [orderId]);

// CORRECT: Orders service holds a denormalized snapshot; customer data synced via events
const order = await orderRepo.findById(orderId);
// customer_name stored in orders table at write time, updated via CustomerUpdated events
```

---

## Cross-References

- `microservices-resilience-patterns` — Circuit Breaker and timeout configuration for the Strangler Fig proxy layer
- `domain-driven-design-patterns` — Bounded Context mapping, Context Map, and Ubiquitous Language alignment needed before designing an ACL
- `event-sourcing-cqrs-patterns` — CDC event replay, idempotent projections, and event-driven synchronisation between old and new stores
- `database-review-patterns` — Schema migration safety: index strategies, lock avoidance, and rollback scripts
- `message-queue-patterns` — Kafka consumer group lag, partitioning strategy, and backpressure during CDC-based migration
- `observability-patterns` — Distributed tracing across the proxy and both the old and new service during shadow testing
