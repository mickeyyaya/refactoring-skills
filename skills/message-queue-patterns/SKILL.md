---
name: message-queue-patterns
description: Use when designing or reviewing event-driven systems — covers Point-to-Point vs Pub/Sub, Competing Consumers, delivery guarantees (at-most-once, at-least-once, exactly-once), Transactional Outbox, Dead Letter Queues, Kafka partition design and consumer groups, message ordering and idempotency, backpressure, and messaging anti-patterns across TypeScript, Java, and Go
---

# Message Queue and Event-Driven Messaging Patterns

## Overview

Message queues decouple producers from consumers, enabling async processing, horizontal scaling, and fault isolation. Incorrect delivery semantics, dual-write hazards, unordered processing, and unbounded queues are among the most costly bugs in distributed systems.

**When to use:** Building async workflows, microservice integrations, event streaming pipelines, background job processors, or any system where services communicate without direct RPC calls.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Point-to-Point | One producer, one consumer per message | Multiple consumers competing without coordination |
| Publish-Subscribe | One producer, many independent consumers | Consumers sharing state or needing ordered delivery |
| Competing Consumers | Multiple workers drain a single queue | No idempotency guard — duplicate processing |
| At-Most-Once | Fire and forget; may lose messages | Using for financial or critical-state updates |
| At-Least-Once | Retry until ack; may duplicate | No idempotency key on consumer side |
| Exactly-Once | Transactional guarantee; no loss, no dup | Ignoring overhead — exactly-once is expensive |
| Transactional Outbox | Write event to DB in same transaction as state | Dual-write without outbox — partial failures |
| Dead Letter Queue | Route unprocessable messages for inspection | Silently dropping poison pill messages |
| Kafka Partitions | Ordered log per partition; parallelism by partition count | Hot partitions, wrong partition key, too few partitions |
| Backpressure | Slow consumers signal producers to slow down | Unbounded in-memory queues causing OOM |

---

## Patterns in Detail

### 1. Point-to-Point vs Publish-Subscribe

**Point-to-Point (Queue):** Each message delivered to exactly one consumer. Use for task distribution — work orders, command processing.
**Publish-Subscribe (Topic):** Each message delivered to all subscribers. Use for event broadcasting — audit logs, cache invalidation, projections.

**Red Flags:**
- Using a queue when multiple systems need the same event (fan-out belongs in pub/sub)
- Using a topic when exactly-one processing is required
- No consumer group isolation — all consumers share the same offset

**TypeScript (AWS SQS vs SNS fan-out):**
```typescript
// Point-to-Point: SQS — one consumer processes each order
async function dispatchOrder(order: Order): Promise<void> {
  await sqs.send(new SendMessageCommand({
    QueueUrl: process.env.ORDER_QUEUE_URL,
    MessageBody: JSON.stringify(order),
    MessageGroupId: order.customerId,  // FIFO — ordered per customer
  }));
}

// Publish-Subscribe: SNS — inventory, notification, analytics each receive every event
async function publishOrderPlaced(event: OrderPlacedEvent): Promise<void> {
  await sns.send(new PublishCommand({
    TopicArn: process.env.ORDER_EVENTS_TOPIC_ARN,
    Message: JSON.stringify(event),
    MessageAttributes: {
      eventType: { DataType: "String", StringValue: "order.placed" },
    },
  }));
}
```

**Go (NATS — queue group vs pub/sub; idiomatic channel-based routing):**
```go
// Pub/Sub — all subscribers receive every message
nc.Subscribe("events.order.placed", func(msg *nats.Msg) {
    var event OrderPlacedEvent
    json.Unmarshal(msg.Data, &event)
    handleOrderPlaced(event)
})

// Queue group — only one worker in the group processes each message
nc.QueueSubscribe("tasks.send-email", "email-workers", func(msg *nats.Msg) {
    var task EmailTask
    json.Unmarshal(msg.Data, &task)
    sendEmail(task)
})
```

---

### 2. Competing Consumers Pattern

Multiple workers drain a shared queue in parallel. Every operation must be idempotent — at-least-once delivery makes duplicates inevitable.

**Red Flags:**
- No idempotency guard — double charge, duplicate record, or corrupted state
- Worker count exceeds partition count on Kafka — extra workers sit idle
- No visibility timeout — two workers process the same message simultaneously

**Java (Spring AMQP — idempotency guard within transaction):**
```java
@RabbitListener(queues = "order.processing", concurrency = "5-20")
@Transactional
public void process(OrderMessage message) {
    if (processedMessages.existsByMessageId(message.getMessageId())) {
        return; // Duplicate — skip
    }
    orderService.fulfill(message.getOrder());
    processedMessages.save(new ProcessedMessage(message.getMessageId(), Instant.now()));
    // Both writes commit or both roll back
}
```

---

### 3. Delivery Guarantees

- **At-Most-Once:** Ack before processing. May lose messages. Use only for metrics/telemetry.
- **At-Least-Once:** Ack after processing. No loss, but duplicates possible. Requires idempotent consumers.
- **Exactly-Once:** Transactional guarantee. Use only when duplicates or loss are unacceptable (payments, inventory). Expensive.

**TypeScript (SQS at-least-once — ack after processing):**
```typescript
async function runConsumer(): Promise<void> {
  while (true) {
    const { Messages } = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: QUEUE_URL,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 20,
    }));

    for (const msg of Messages ?? []) {
      try {
        await processEvent(JSON.parse(msg.Body!));
        await sqs.send(new DeleteMessageCommand({   // Ack AFTER success
          QueueUrl: QUEUE_URL,
          ReceiptHandle: msg.ReceiptHandle!,
        }));
      } catch (err) {
        // Do NOT delete — SQS redelivers, then routes to DLQ after maxReceiveCount
      }
    }
  }
}
```

**Java (Kafka exactly-once — Spring `@Transactional` + KafkaTransactionManager):**
```java
@Transactional("kafkaTransactionManager")
public void processAndForward(ConsumerRecord<String, String> record) {
    PaymentEvent event = deserialize(record.value());
    PaymentResult result = paymentService.process(event);
    // Producer send and consumer offset commit are atomic
    kafkaTemplate.send("payment.results", event.getOrderId(), serialize(result));
}
```

---

### 4. Transactional Outbox Pattern

Writing to DB and publishing an event are two separate operations. A crash between them leaves them inconsistent. Write the event into an `outbox` table in the same DB transaction, then relay asynchronously.

**Red Flags:**
- Publishing directly to broker alongside a DB write — crash = lost or phantom event
- Outbox table grows unbounded — no cleanup of relayed events
- No idempotency on relay — re-relay causes duplicate publish

**TypeScript (Outbox write + relay with PostgreSQL):**
```typescript
// Step 1: Atomic state + event write
async function placeOrder(order: NewOrder): Promise<Order> {
  return db.transaction(async (tx) => {
    const saved = await tx.insert(orders).values(order).returning().get();
    await tx.insert(outboxEvents).values({
      id: crypto.randomUUID(),
      eventType: "order.placed",
      payload: JSON.stringify(saved),
      relayed: false,
    });
    return saved;
  });
}

// Step 2: Relay polls outbox
async function relayOutboxEvents(): Promise<void> {
  const pending = await db.select().from(outboxEvents)
    .where(eq(outboxEvents.relayed, false))
    .limit(100)
    .for("update skip locked");  // Prevents concurrent relay picking same rows

  for (const evt of pending) {
    await broker.publish(evt.eventType, evt.payload);
    await db.update(outboxEvents)
      .set({ relayed: true, relayedAt: new Date() })
      .where(eq(outboxEvents.id, evt.id));
  }
}
```

Cross-reference: `event-sourcing-cqrs-patterns` — Event Store is the authoritative outbox when event sourcing is in use; no separate outbox table needed.

---

### 5. Dead Letter Queues and Poison Pill Messages

A DLQ captures messages that cannot be processed after exhausting retries. Without a DLQ, poison pills block the queue or cause infinite retry loops.

**Red Flags:**
- No retry limit — poison pill starves valid messages (critical in ordered queues)
- DLQ exists but no alert on DLQ depth — silent data loss
- Consumer catches all exceptions and acks — data loss with no audit trail
- No replay tooling — events stuck forever with no recovery path

**TypeScript (RabbitMQ — DLQ via dead-letter-exchange):**
```typescript
await channel.assertExchange("orders.dlx", "direct", { durable: true });
await channel.assertQueue("orders.dlq", { durable: true });
await channel.bindQueue("orders.dlq", "orders.dlx", "orders");

await channel.assertQueue("orders", {
  durable: true,
  arguments: {
    "x-dead-letter-exchange": "orders.dlx",
    "x-dead-letter-routing-key": "orders",
    "x-message-ttl": 30_000,
    "x-max-delivery-count": 3,
  },
});

channel.consume("orders", async (msg) => {
  if (!msg) return;
  try {
    await processOrder(JSON.parse(msg.content.toString()));
    channel.ack(msg);
  } catch (err) {
    const deliveryCount = (msg.properties.headers?.["x-death"]?.[0]?.count ?? 0) + 1;
    channel.nack(msg, false, deliveryCount < 3);  // requeue until limit, then DLX
  }
});
```

**Go (Kafka — manual DLQ routing with diagnostic headers):**
```go
func consume(ctx context.Context, reader *kafka.Reader, dlqWriter *kafka.Writer) {
    for {
        msg, err := reader.FetchMessage(ctx)
        if err != nil { break }

        if processErr := handleMessage(msg); processErr != nil {
            dlqErr := dlqWriter.WriteMessages(ctx, kafka.Message{
                Key:   msg.Key,
                Value: msg.Value,
                Headers: []kafka.Header{
                    {Key: "dlq-reason", Value: []byte(processErr.Error())},
                    {Key: "dlq-source-topic", Value: []byte(msg.Topic)},
                    {Key: "dlq-source-offset", Value: []byte(fmt.Sprintf("%d", msg.Offset))},
                },
            })
            if dlqErr != nil {
                log.Printf("CRITICAL: DLQ write failed: %v", dlqErr)
                continue // Do NOT commit offset — retry
            }
        }
        reader.CommitMessages(ctx, msg)
    }
}
```

Cross-reference: `microservices-resilience-patterns` — Circuit Breaker and Retry patterns complement DLQ for transient vs. permanent failures.

---

### 6. Kafka Partition Design and Consumer Groups

- Partition count = maximum consumer parallelism. More consumers than partitions = idle consumers.
- Partition key determines which partition a message lands in. Related messages must share the same key for ordering.
- Consumer groups provide independent consumption — each group has its own offset per partition.
- Rebalancing (adding/removing consumers) causes brief pauses; minimize with sticky assignors.

**Red Flags:**
- `null` partition key — round-robin breaks ordering for related events
- Partition count = 1 — no parallelism
- Single consumer group for two independent services — shared offsets interfere
- Hot partition — one high-volume key overwhelms one partition

**Java (producer with partition key for per-order ordering):**
```java
public void publishOrderEvent(OrderEvent event) {
    var record = new ProducerRecord<>("order-events", event.getOrderId(), event);
    kafkaTemplate.send(record)
        .addCallback(
            result -> log.debug("offset={}", result.getRecordMetadata().offset()),
            ex -> log.error("publish failed order={}", event.getOrderId(), ex)
        );
}
```

**TypeScript (consumer group with concurrent partition processing):**
```typescript
const consumer = kafka.consumer({ groupId: "inventory-service-group" });
await consumer.connect();
await consumer.subscribe({ topic: "order-events", fromBeginning: false });

await consumer.run({
  partitionsConsumedConcurrently: 4,
  eachMessage: async ({ partition, message }) => {
    const event = JSON.parse(message.value!.toString()) as OrderEvent;
    await inventoryService.reserve(event);
  },
});
```

**Go (Sarama ConsumerGroupHandler — rebalance lifecycle):**
```go
type OrderConsumerGroup struct{ svc OrderService }

func (c *OrderConsumerGroup) Setup(kafka.ConsumerGroupSession) error   { return nil }
func (c *OrderConsumerGroup) Cleanup(kafka.ConsumerGroupSession) error { return nil }

func (c *OrderConsumerGroup) ConsumeClaim(session kafka.ConsumerGroupSession, claim kafka.ConsumerGroupClaim) error {
    for msg := range claim.Messages() {
        var event OrderEvent
        if err := json.Unmarshal(msg.Value, &event); err != nil {
            session.MarkMessage(msg, "")
            continue
        }
        if err := c.svc.Process(session.Context(), event); err != nil {
            return err // Stop — trigger rebalance and retry
        }
        session.MarkMessage(msg, "")
    }
    return nil
}
```

---

### 7. Message Ordering and Idempotency

Distributed systems deliver messages out of order. Design consumers as idempotent and order-tolerant unless strict ordering is enforced by infrastructure (single Kafka partition per entity).

**Idempotency strategies:**
1. **Idempotency key:** Track processed message IDs; skip duplicates.
2. **Conditional update:** `UPDATE ... WHERE version = expectedVersion` — reject stale updates.
3. **Deduplication window:** Accept duplicate within a TTL; discard thereafter.

**Ordering strategies:**
1. Partition by entity ID — all events for an entity go to the same partition.
2. Sequence numbers — consumers detect gaps and buffer out-of-order messages.
3. Optimistic concurrency — state updates carry expected sequence; reject on mismatch.

**Red Flags:**
- No idempotency guard with at-least-once delivery — duplicates corrupt state
- Assuming global order across partitions — only partition-level order is guaranteed
- Sequence number gaps not handled — out-of-order silently skips events

**TypeScript (conditional update with sequence check):**
```typescript
async function applyInventoryEvent(event: InventoryEvent): Promise<void> {
  const result = await db.update(inventory)
    .set({ quantity: sql`quantity + ${event.delta}`, lastSequence: event.sequenceNumber })
    .where(and(
      eq(inventory.productId, event.productId),
      eq(inventory.lastSequence, event.sequenceNumber - 1)  // reject if not next-in-sequence
    ));

  if (result.rowsAffected === 0) {
    const current = await db.select().from(inventory).where(eq(inventory.productId, event.productId)).get();
    if (current && current.lastSequence >= event.sequenceNumber) {
      log.info("Duplicate discarded", { messageId: event.messageId });
    } else {
      log.warn("Out-of-order — buffering", { messageId: event.messageId });
      await eventBuffer.store(event);
    }
  }
}
```

Cross-reference: `event-sourcing-cqrs-patterns` — Event Store append semantics naturally provide idempotency via sequence position.

---

### 8. Backpressure in Messaging Systems

Without backpressure, fast producers fill in-memory queues causing OOM crashes.

**Mechanisms:** Pull-based Kafka (consumer controls fetch rate); AMQP `basicQos(prefetchCount)` (limits in-flight unacked messages); producer token bucket; Reactive Streams `Publisher.request(n)`.

**Red Flags:** `prefetchCount = 0` dumps all messages into consumer memory; unbounded in-memory buffer → OOM; ignoring Kafka consumer lag.

**TypeScript (RabbitMQ prefetch + bounded concurrency):**
```typescript
await channel.prefetch(10);  // Max 10 unacknowledged messages per consumer

const processingQueue = new PQueue({ concurrency: 5 });

channel.consume("orders", (msg) => {
  if (!msg) return;
  processingQueue.add(async () => {
    try {
      await processOrder(JSON.parse(msg.content.toString()));
      channel.ack(msg);
    } catch (err) {
      channel.nack(msg, false, false);  // Send to DLQ
    }
  });
});
```

**Go (channel-based backpressure — bounded channel blocks reader when workers saturated):**
```go
func startWorkerPool(ctx context.Context, reader *kafka.Reader, workerCount int) {
    work := make(chan kafka.Message, workerCount*2)  // Bounded: blocks when full
    var wg sync.WaitGroup
    for i := 0; i < workerCount; i++ {
        wg.Add(1)
        go func() { defer wg.Done(); for msg := range work { handleMessage(ctx, msg) } }()
    }
    for {
        msg, err := reader.FetchMessage(ctx)
        if err != nil { break }
        work <- msg  // Natural backpressure: blocks until a worker is free
        reader.CommitMessages(ctx, msg)
    }
    close(work); wg.Wait()
}
```

Cross-reference: `data-pipeline-patterns` — Streaming backpressure with Reactive Streams in data pipeline contexts.

---

### 9. Messaging Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Fire-and-Forget without DLQ** | No retry, no DLQ, no ack confirmation | Add DLQ + monitoring; use at-least-once with ack |
| **Unbounded Queue** | Queue depth grows without consumer keeping pace | Implement backpressure; alert on depth; add consumers |
| **Poison Pill** | Malformed message blocks queue with infinite retries | Set retry limit; route to DLQ; validate schema at publish |
| **Chatty Messaging** | Hundreds of tiny messages where one batch would do | Batch related events; use compacted topics for state |
| **Dual-Write Without Outbox** | DB and broker writes in separate operations | Use Transactional Outbox or event sourcing |
| **Shared Consumer Group** | Two independent services share one group ID | Each service must have its own group ID |
| **Missing Idempotency** | No deduplication guard with at-least-once delivery | Check idempotency key before every state mutation |
| **Global Ordering Assumption** | Assuming total order across partitions | Enforce ordering only where needed: single partition per entity |
| **No Observability** | No metrics on queue depth, consumer lag, or DLQ depth | Instrument all queues; alert on lag, DLQ growth, errors |

**Poison Pill — bounded retry with backoff:**
```typescript
async function goodConsumer(msg: Message, attempt: number): Promise<void> {
  try {
    await process(msg);
    await ack(msg);
  } catch (err) {
    if (attempt >= 3) {
      await dlq.publish(msg, { reason: String(err), attempt });
      await ack(msg);  // Ack original to unblock the queue
    } else {
      await nack(msg, { requeue: true, delay: 2 ** attempt * 1000 });
    }
  }
}
```

---

## Cross-References

- `microservices-resilience-patterns` — Retry, Circuit Breaker, and Bulkhead patterns complement at-least-once delivery and DLQ routing
- `event-sourcing-cqrs-patterns` — Event Store as authoritative outbox; CQRS projections as pub/sub consumers
- `data-pipeline-patterns` — Streaming backpressure, windowed aggregation, and exactly-once semantics
- `observability-patterns` — Queue depth, consumer lag, and DLQ depth instrumentation; alerting thresholds
- `concurrency-patterns` — Producer-Consumer with bounded channels; async task coordination
