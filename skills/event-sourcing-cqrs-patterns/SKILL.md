---
name: event-sourcing-cqrs-patterns
description: Use when designing or reviewing systems that store state as an immutable sequence of events — covers Event Sourcing fundamentals, CQRS, projections and read models, snapshot strategy, aggregate replay, event schema evolution and upcasting, eventual consistency, idempotency, and anti-patterns across TypeScript, Java, and Go
---

# Event Sourcing and CQRS Patterns

## Overview

Traditional CRUD stores only current state — once you update a record, the history is gone. Event Sourcing inverts this: every state change is recorded as an immutable event appended to an event log. The current state is always derived by replaying events. CQRS (Command Query Responsibility Segregation) separates the write side (commands that emit events) from the read side (projections that build optimized query models).

**When to use:** Audit trail requirements, financial ledgers, collaborative editing, domain-driven systems with complex business rules, systems needing temporal queries ("what was the balance on date X?"), or microservice architectures requiring reliable async integration.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Event Store | Append-only log of domain events | Mutable events, missing sequence numbers |
| CQRS | Separate write model (commands) from read model (queries) | Single model that is both read and written |
| Projection / Read Model | Build query-optimized view from events | Projections tightly coupled to event internals |
| Snapshot | Checkpoint aggregate state to skip full replay | Snapshots taken too rarely or too often |
| Aggregate Replay | Rebuild aggregate by replaying its event stream | Loading entire global log instead of per-aggregate stream |
| Event Versioning / Upcasting | Migrate old event schemas to new versions | Breaking schema changes without versioning |
| Eventual Consistency | Accept that read models lag behind the write model | Assuming reads are always current after a write |
| Idempotency / At-Least-Once | Process duplicate events safely | Missing deduplication in event handlers |

---

## Patterns in Detail

### 1. Event Sourcing Fundamentals — Event Store and Append-Only Log

The event store is the single source of truth. Events are facts — immutable records of things that happened. The event log is append-only: you never update or delete events.

**Core concepts:**
- Each event has a stream ID (aggregate ID), a sequence number (position in that stream), an event type, a payload, and a timestamp.
- Optimistic concurrency: when appending, pass the expected version; the store rejects if another writer advanced it first.
- The global event log can reconstruct any state at any point in time.

**Red Flags:**
- Events modified or deleted after write — destroys auditability
- Missing sequence numbers — cannot detect gaps or enforce ordering
- Storing commands, not events: `CreateUserCommand` is a command; `UserCreated` is an event
- Events named with CRUD verbs (`UserUpdated`) instead of domain facts (`UserEmailChanged`)
- Storing the full aggregate state in the event payload — defeats the purpose

**TypeScript — minimal event store interface:**
```typescript
type DomainEvent = {
  readonly streamId: string;
  readonly version: number;
  readonly type: string;
  readonly occurredAt: Date;
  readonly payload: Readonly<Record<string, unknown>>;
};

interface EventStore {
  append(streamId: string, events: DomainEvent[], expectedVersion: number): Promise<void>;
  load(streamId: string, fromVersion?: number): Promise<DomainEvent[]>;
}

// Usage: optimistic concurrency check
async function processCommand(cmd: CreateOrderCmd, store: EventStore): Promise<void> {
  const events = await store.load(cmd.orderId);
  const order = replayOrder(events);                   // rebuild from history
  const newEvents = order.placeOrder(cmd);             // domain logic produces events
  await store.append(cmd.orderId, newEvents, order.version); // expected version guards race conditions
}
```

**Java — event envelope:**
```java
public record DomainEvent(
    String streamId,
    int version,
    String type,
    Instant occurredAt,
    Map<String, Object> payload   // immutable at runtime via Collections.unmodifiableMap
) {}

public interface EventStore {
    void append(String streamId, List<DomainEvent> events, int expectedVersion);
    List<DomainEvent> load(String streamId);
    List<DomainEvent> load(String streamId, int fromVersion);
}
```

**Go — append with optimistic locking:**
```go
type DomainEvent struct {
    StreamID    string
    Version     int
    Type        string
    OccurredAt  time.Time
    Payload     json.RawMessage
}

type EventStore interface {
    Append(streamID string, events []DomainEvent, expectedVersion int) error
    Load(streamID string, fromVersion int) ([]DomainEvent, error)
}

// ErrConcurrencyConflict is returned when expectedVersion does not match.
var ErrConcurrencyConflict = errors.New("concurrency conflict")
```

---

### 2. CQRS — Command Query Responsibility Segregation

Commands change state and produce events. Queries read from optimized projections. The two models never share the same data structure.

**Red Flags:**
- A single repository used for both reads and writes — read concerns pollute the write model
- Commands returning rich query data — violates the segregation boundary
- Synchronous projection updates inside the command transaction — defeats scalability
- No command validation before dispatching — invalid commands consume resources before failing

**TypeScript — command handler produces events; query hits read model:**
```typescript
// --- Write side ---
type PlaceOrderCommand = { orderId: string; customerId: string; items: OrderItem[] };

class OrderCommandHandler {
  constructor(private store: EventStore) {}

  async handle(cmd: PlaceOrderCommand): Promise<void> {
    const history = await this.store.load(cmd.orderId);
    const order = OrderAggregate.replay(history);
    const events = order.place(cmd);           // domain rules, no DB reads here
    await this.store.append(cmd.orderId, events, order.version);
  }
}

// --- Read side ---
type OrderSummary = { orderId: string; status: string; total: number };

interface OrderQueryRepository {
  findById(orderId: string): Promise<OrderSummary | null>;
  findByCustomer(customerId: string): Promise<OrderSummary[]>;
}

// Controller keeps the two sides separate
class OrderController {
  constructor(
    private commands: OrderCommandHandler,
    private queries: OrderQueryRepository,
  ) {}

  async placeOrder(cmd: PlaceOrderCommand): Promise<void> {
    await this.commands.handle(cmd);
    // Return 202 Accepted — the read model will update asynchronously
  }

  async getOrder(id: string): Promise<OrderSummary | null> {
    return this.queries.findById(id);          // never touches the event store
  }
}
```

**Java — using MediatR-style dispatch:**
```java
public record PlaceOrderCommand(String orderId, String customerId, List<OrderItem> items)
    implements Command {}

@Component
public class PlaceOrderHandler implements CommandHandler<PlaceOrderCommand> {
    private final EventStore store;

    @Override
    public void handle(PlaceOrderCommand cmd) {
        var history = store.load(cmd.orderId());
        var order = OrderAggregate.replay(history);
        var events = order.place(cmd);
        store.append(cmd.orderId(), events, order.version());
    }
}

// Query side — completely separate Spring Data repository projecting onto a read table
public interface OrderSummaryRepository extends JpaRepository<OrderSummaryView, String> {
    List<OrderSummaryView> findByCustomerId(String customerId);
}
```

---

### 3. Projections, Read Models, and View Models

A projection is a function from an event stream to a read-optimized data structure. It subscribes to events and updates the read model (view model) stored in a queryable store (SQL table, Redis, Elasticsearch, etc.).

**Red Flags:**
- Projection directly reads from the event store on every query — defeats the purpose
- Projection contains business logic — projections should only reshape data
- No idempotency in projection handlers — replaying events corrupts the read model
- Projection deletes and rebuilds the entire read model on every event — does not scale
- Single projection coupled to multiple aggregates' internal details

**TypeScript — idempotent projection handler:**
```typescript
type OrderPlaced = { orderId: string; customerId: string; total: number; status: 'placed' };
type OrderShipped = { orderId: string; shippedAt: string; status: 'shipped' };

class OrderProjection {
  constructor(private db: Database) {}

  async on(event: DomainEvent): Promise<void> {
    // Idempotent: use UPSERT with the event version as the cursor
    switch (event.type) {
      case 'OrderPlaced': {
        const p = event.payload as OrderPlaced;
        await this.db.upsert('order_summary', {
          order_id: p.orderId,
          customer_id: p.customerId,
          total: p.total,
          status: p.status,
          last_event_version: event.version,
        }, { conflictOn: 'order_id' });
        break;
      }
      case 'OrderShipped': {
        const p = event.payload as OrderShipped;
        await this.db.update('order_summary',
          { status: p.status, shipped_at: p.shippedAt, last_event_version: event.version },
          { where: 'order_id = ? AND last_event_version < ?', params: [p.orderId, event.version] },
        );
        break;
      }
    }
  }
}
```

**Go — projection rebuilder (for replaying from scratch):**
```go
func RebuildOrderSummary(store EventStore, db *sql.DB) error {
    events, err := store.Load("*", 0)  // load all order events
    if err != nil {
        return fmt.Errorf("RebuildOrderSummary: load: %w", err)
    }
    for _, e := range events {
        if err := applyToReadModel(e, db); err != nil {
            return fmt.Errorf("RebuildOrderSummary: apply %s v%d: %w", e.StreamID, e.Version, err)
        }
    }
    return nil
}
```

Cross-reference: `domain-driven-design` — Bounded Contexts: each context can own its own projection of shared events.

---

### 4. Snapshot Strategy and Aggregate Replay

Replaying hundreds of events on every command is slow. Snapshots capture aggregate state at a version checkpoint. On the next load, fetch the snapshot, then replay only events after it.

**Red Flags:**
- Snapshot taken on every event — write amplification, no benefit
- Snapshot never taken — aggregates with long histories become slow over time
- Snapshot format tightly coupled to internal aggregate fields — hard to evolve
- Snapshot store is inconsistent with event store — replay produces wrong state
- Snapshots stored in the event stream — mixes concerns

**TypeScript — snapshot-aware aggregate loading:**
```typescript
type Snapshot<T> = { streamId: string; version: number; state: T };

interface SnapshotStore<T> {
  save(snapshot: Snapshot<T>): Promise<void>;
  load(streamId: string): Promise<Snapshot<T> | null>;
}

async function loadAggregate(
  id: string,
  eventStore: EventStore,
  snapshotStore: SnapshotStore<OrderState>,
): Promise<OrderAggregate> {
  const snapshot = await snapshotStore.load(id);
  const fromVersion = snapshot ? snapshot.version + 1 : 0;
  const events = await eventStore.load(id, fromVersion);

  let aggregate: OrderAggregate;
  if (snapshot) {
    aggregate = OrderAggregate.fromSnapshot(snapshot.state, snapshot.version);
  } else {
    aggregate = OrderAggregate.empty();
  }
  return aggregate.replay(events);
}

// Save a snapshot every N events
const SNAPSHOT_THRESHOLD = 50;
async function saveIfNeeded(agg: OrderAggregate, store: SnapshotStore<OrderState>): Promise<void> {
  if (agg.version % SNAPSHOT_THRESHOLD === 0) {
    await store.save({ streamId: agg.id, version: agg.version, state: agg.toState() });
  }
}
```

**Java — aggregate replay with snapshot:**
```java
public class OrderAggregate {
    private String id;
    private String status;
    private int version;

    public static OrderAggregate replay(List<DomainEvent> events) {
        return events.stream().reduce(
            new OrderAggregate(),
            OrderAggregate::apply,
            (a, b) -> b   // combiner unused in sequential stream
        );
    }

    public static OrderAggregate fromSnapshot(OrderSnapshot snap) {
        var agg = new OrderAggregate();
        agg.id = snap.orderId();
        agg.status = snap.status();
        agg.version = snap.version();
        return agg;
    }

    private OrderAggregate apply(DomainEvent event) {
        // Return new instance — immutable evolution
        var next = new OrderAggregate();
        next.id = this.id;
        next.version = event.version();
        next.status = switch (event.type()) {
            case "OrderPlaced" -> "placed";
            case "OrderShipped" -> "shipped";
            default -> this.status;
        };
        return next;
    }
}
```

---

### 5. Event Schema Evolution and Upcasting / Event Versioning

Events are permanent. When the schema changes, you cannot alter old events — you upcast them to the new format at read time.

**Red Flags:**
- Breaking schema change (rename/remove field) on an existing event type — crashes replays
- No version field on events — cannot distinguish v1 from v2 payloads
- Upcast logic scattered across multiple projections — each must be updated independently
- Upcasting mutates the stored event — violates immutability of the log
- Treating schema evolution as an infrastructure problem instead of a domain problem

**TypeScript — upcaster pipeline:**
```typescript
type EventV1 = { type: 'UserRegistered'; version: 1; email: string };
type EventV2 = { type: 'UserRegistered'; version: 2; email: string; username: string };

function upcastUserRegistered(raw: EventV1 | EventV2): EventV2 {
  if (raw.version === 2) return raw;
  // v1 → v2: derive username from email local part
  return { ...raw, version: 2, username: raw.email.split('@')[0] };
}

// Apply upcasters before handing events to aggregates or projections
function upcast(event: DomainEvent): DomainEvent {
  if (event.type === 'UserRegistered') {
    const payload = upcastUserRegistered(event.payload as EventV1 | EventV2);
    return { ...event, payload };
  }
  return event;
}

// Load pipeline: raw events → upcast → replay
async function loadUser(id: string, store: EventStore): Promise<UserAggregate> {
  const raw = await store.load(id);
  const upcasted = raw.map(upcast);
  return UserAggregate.replay(upcasted);
}
```

**Java — versioned event with upcaster registry:**
```java
public interface Upcaster {
    String eventType();
    int fromVersion();
    Map<String, Object> upcast(Map<String, Object> payload);
}

@Component
public class UserRegisteredV1ToV2 implements Upcaster {
    public String eventType() { return "UserRegistered"; }
    public int fromVersion() { return 1; }

    public Map<String, Object> upcast(Map<String, Object> payload) {
        var result = new LinkedHashMap<>(payload);
        result.put("version", 2);
        result.computeIfAbsent("username",
            k -> ((String) payload.get("email")).split("@")[0]);
        return Collections.unmodifiableMap(result);
    }
}
```

**Go — version tag in payload:**
```go
type RawEvent struct {
    Type    string          `json:"type"`
    Version int             `json:"version"`
    Payload json.RawMessage `json:"payload"`
}

func upcastAll(raw []RawEvent) []RawEvent {
    result := make([]RawEvent, len(raw))
    for i, e := range raw {
        result[i] = upcastOne(e)  // returns new RawEvent, never modifies in place
    }
    return result
}
```

Cross-reference: `architectural-patterns` — Strangler Fig: use event versioning when migrating event schemas incrementally alongside system evolution.

---

### 6. Eventual Consistency and Idempotency / At-Least-Once Delivery

Read models are eventually consistent — there is a lag between a command being processed and the projection updating. Message brokers guarantee at-least-once delivery, so projections must be idempotent.

**Red Flags:**
- Read-your-own-writes assumption — querying the read model immediately after a write and expecting the new state
- No deduplication — same event applied twice causes double-counting or duplicate rows
- No event ordering guarantee enforced — out-of-order events corrupt the read model
- Missing idempotency key on external API calls triggered by events — double charges, double emails
- Projection handler that fails partially and cannot be safely retried

**TypeScript — idempotent event handler with deduplication table:**
```typescript
async function handleEvent(event: DomainEvent, db: Database): Promise<void> {
  const dedupeKey = `${event.streamId}:${event.version}`;

  await db.transaction(async (tx) => {
    // Guard: skip if already processed (idempotent at-least-once safety)
    const existing = await tx.queryOne(
      'SELECT 1 FROM processed_events WHERE dedupe_key = ?', [dedupeKey]
    );
    if (existing) return;  // duplicate delivery — safe to skip

    // Apply to read model
    await applyToReadModel(event, tx);

    // Mark as processed within same transaction
    await tx.execute(
      'INSERT INTO processed_events (dedupe_key, processed_at) VALUES (?, NOW())',
      [dedupeKey]
    );
  });
}
```

**Java — idempotent consumer with Spring and JPA:**
```java
@Transactional
public void onEvent(DomainEvent event) {
    var key = event.streamId() + ":" + event.version();
    if (processedEventRepository.existsByDedupeKey(key)) return;

    applyToReadModel(event);
    processedEventRepository.save(new ProcessedEvent(key, Instant.now()));
}
```

**Go — at-least-once consumer with explicit acknowledgment:**
```go
func (c *Consumer) Process(ctx context.Context, msg Message) error {
    key := fmt.Sprintf("%s:%d", msg.StreamID, msg.Version)
    ok, err := c.dedupe.AlreadyProcessed(ctx, key)
    if err != nil {
        return fmt.Errorf("dedupe check: %w", err)
    }
    if ok {
        return nil  // idempotent skip — ack without reprocessing
    }
    if err := c.apply(ctx, msg); err != nil {
        return err  // do NOT ack — broker will redeliver
    }
    return c.dedupe.MarkProcessed(ctx, key)
}
```

Cross-reference: `microservices-resilience` — Outbox Pattern: guarantee at-least-once event delivery from a service's own database transaction.

---

### 7. Anti-Patterns, Pitfalls, and When NOT to Use

#### Anti-Pattern Table

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Event Store as Message Bus** | Using the event store for inter-service messaging instead of a broker | Use an outbox table + broker for cross-service events; keep the event store internal |
| **Anemic Events** | Events carry only IDs, forcing projections to query the write side | Include all data a projection needs in the event payload |
| **Fat Events** | Events include the entire aggregate state as a snapshot | Include only what changed; avoid coupling projections to full state |
| **God Aggregate** | One aggregate owns thousands of events and must replay all of them | Split by sub-domain; use snapshots; redesign aggregate boundaries |
| **Synchronous Projection** | Projection updated in the same HTTP request/transaction as the command | Accept eventual consistency; return 202; poll or use WebSocket for updates |
| **Mutable Events** | Updating event payloads after storage to "fix" data | Emit a corrective event (`OrderCorrected`) instead of altering history |
| **Missing Correlation ID** | No way to trace a chain of events back to the originating command | Stamp every event with `correlationId` and `causationId` |
| **Projection Coupling** | Projection reads fields renamed during upcasting without going through the upcaster | All event consumers must go through the upcaster pipeline |

#### When NOT to Use Event Sourcing

Event sourcing adds significant operational complexity. Avoid it when:

- **Simple CRUD is sufficient** — user profiles, CMS content, configuration — no audit trail needed, no complex domain rules.
- **Team lacks DDD fluency** — event sourcing without domain-driven design produces anemic event logs that are hard to reason about.
- **Query patterns are the priority** — if the system is primarily read-heavy with simple writes, a well-indexed relational database is simpler and faster.
- **Event volume is extreme** — billions of events per aggregate stream require aggressive snapshotting and partitioned storage, adding significant infra burden.
- **Eventual consistency is unacceptable** — financial settlement, regulatory reporting that requires strong consistency between write and read at all times.
- **Small team, short timeline** — the overhead of event store, projections, upcasters, and CQRS routing is substantial; choose it deliberately.

**TypeScript — "do you need this?" decision checklist:**
```typescript
// Use event sourcing if you can answer YES to at least 2:
const criteria = {
  needsAuditTrail: true,           // "who changed what and when?"
  needsTemporalQuery: true,        // "what was the state at time T?"
  complexDomainRules: true,        // domain logic that produces events naturally
  asyncIntegration: true,          // other services need to react to state changes
  collaborativeEditing: false,     // multiple actors on same aggregate concurrently
};
const score = Object.values(criteria).filter(Boolean).length;
if (score < 2) console.warn('Event sourcing may be over-engineering for this use case');
```

---

## Event Sourcing and CQRS Checklist

Before shipping an event-sourced system:

- [ ] Events are named as past-tense domain facts (`OrderPlaced`, not `CreateOrder`)
- [ ] Event store is append-only — no UPDATE or DELETE on event rows
- [ ] Optimistic concurrency enforced on `append` (expected version check)
- [ ] All projections are idempotent — safe to replay the full event log
- [ ] Deduplication table or equivalent prevents double-processing at-least-once events
- [ ] Every event type has a version field; upcasters registered for all old versions
- [ ] Snapshot threshold configured; snapshot store separate from event store
- [ ] Correlation ID and causation ID stamped on every event
- [ ] Read model lag is monitored and alerted (projection lag metric)
- [ ] At least one "rebuild projection from scratch" runbook exists and is tested

---

## Cross-References

- `architectural-patterns` — Event-Driven Architecture: how event sourcing fits into broader async system topologies; Strangler Fig for incremental migration
- `microservices-resilience-patterns` — Outbox Pattern: reliable at-least-once delivery from service transactions; Saga: orchestrating long-running processes across event-sourced aggregates
- `domain-driven-design-patterns` — Aggregates and Bounded Contexts: event sourcing works best when aggregate boundaries are well-defined by DDD; domain events as the vocabulary
