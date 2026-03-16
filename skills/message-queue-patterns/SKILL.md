---
name: message-queue-patterns
description: Use when designing or reviewing event-driven systems — covers Point-to-Point vs Pub/Sub, Competing Consumers, delivery guarantees (at-most-once, at-least-once, exactly-once), Transactional Outbox, Dead Letter Queues, Kafka partition design and consumer groups, message ordering and idempotency, backpressure, and messaging anti-patterns across TypeScript, Java, and Go
---

# Message Queue and Event-Driven Messaging Patterns

## Overview

Message queues and event-driven architectures decouple producers from consumers, enabling asynchronous processing, horizontal scaling, and fault isolation. However, incorrect delivery semantics, dual-write hazards, unordered processing, and unbounded queues are among the most costly bugs in distributed systems. Use this guide when designing or reviewing messaging pipelines, event buses, and queue-based integrations.

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

**Point-to-Point (Queue):** Each message is delivered to exactly one consumer. Ideal for task distribution — work orders, job queues, command processing.

**Publish-Subscribe (Topic/Exchange):** Each message is delivered to all subscribers independently. Ideal for event broadcasting — audit logs, cache invalidation, downstream projections.

**Red Flags:**
- Using a queue when multiple systems need the same event independently (fan-out belongs in pub/sub)
- Using a topic when exactly-one processing is required (ordering and exclusive consumption belong in a queue)
- No consumer group isolation on a topic — all consumers share the same offset, consuming the same messages instead of independently

**TypeScript (AWS SQS vs SNS fan-out):**
```typescript
// Point-to-Point: SQS queue — one consumer processes each order
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";

const sqs = new SQSClient({ region: "us-east-1" });

async function dispatchOrder(order: Order): Promise<void> {
  await sqs.send(new SendMessageCommand({
    QueueUrl: process.env.ORDER_QUEUE_URL,
    MessageBody: JSON.stringify(order),
    MessageGroupId: order.customerId,   // FIFO queue — ordered per customer
  }));
}

// Publish-Subscribe: SNS topic — multiple downstream services each receive every event
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

const sns = new SNSClient({ region: "us-east-1" });

async function publishOrderPlaced(event: OrderPlacedEvent): Promise<void> {
  await sns.send(new PublishCommand({
    TopicArn: process.env.ORDER_EVENTS_TOPIC_ARN,
    Message: JSON.stringify(event),
    MessageAttributes: {
      eventType: { DataType: "String", StringValue: "order.placed" },
    },
  }));
  // Subscribers: inventory-service, notification-service, analytics-service
  // Each receives an independent copy via their own SQS subscription
}
```

**Go (NATS — pub/sub vs queue group):**
```go
// Pub/Sub — all subscribers receive every message
nc.Subscribe("events.order.placed", func(msg *nats.Msg) {
    var event OrderPlacedEvent
    json.Unmarshal(msg.Data, &event)
    handleOrderPlaced(event)
})

// Queue group (point-to-point) — only one worker in the group processes each message
nc.QueueSubscribe("tasks.send-email", "email-workers", func(msg *nats.Msg) {
    var task EmailTask
    json.Unmarshal(msg.Data, &task)
    sendEmail(task)
})
```

---

### 2. Competing Consumers Pattern

Multiple workers drain a shared queue in parallel, scaling throughput linearly with worker count. The critical constraint: every operation must be idempotent, because at-least-once delivery means duplicates are inevitable.

**Red Flags:**
- No idempotency guard — a message delivered twice causes a double charge, duplicate record, or corrupted state
- Worker count exceeds partition count on Kafka — extra workers sit idle
- No visibility timeout / lock duration — two workers process the same message simultaneously
- Worker crashes after processing but before ack — message redelivered and processed again

**Java (Spring AMQP — competing consumers with idempotency):**
```java
@Service
public class OrderProcessor {

    private final ProcessedMessageRepository processedMessages;
    private final OrderService orderService;

    @RabbitListener(queues = "order.processing", concurrency = "5-20")
    @Transactional
    public void process(OrderMessage message) {
        // Idempotency guard: skip if already processed
        if (processedMessages.existsByMessageId(message.getMessageId())) {
            log.info("Duplicate message skipped: {}", message.getMessageId());
            return;
        }

        try {
            orderService.fulfill(message.getOrder());
            // Record as processed within the same transaction
            processedMessages.save(new ProcessedMessage(message.getMessageId(), Instant.now()));
        } catch (NonRetryableException e) {
            log.error("Non-retryable failure, routing to DLQ: {}", message.getMessageId(), e);
            throw new AmqpRejectAndDontRequeueException(e);
        }
        // Retryable exceptions propagate — RabbitMQ redelivers up to maxAttempts
    }
}
```

**Go (competing consumers with a distributed lock via Redis):**
```go
func processMessage(ctx context.Context, msg Message, redis *redis.Client, svc OrderService) error {
    lockKey := "processed:" + msg.ID
    // NX = set only if not exists, EX = expiry
    set, err := redis.SetNX(ctx, lockKey, "1", 24*time.Hour).Result()
    if err != nil {
        return fmt.Errorf("lock check failed: %w", err)
    }
    if !set {
        log.Printf("duplicate message skipped: %s", msg.ID)
        return nil // Already processed — ack without reprocessing
    }
    return svc.Fulfill(ctx, msg.Order)
}
```

---

### 3. Delivery Guarantees

**At-Most-Once:** Acknowledge before processing. Message may be lost if the consumer crashes mid-processing. Acceptable only for metrics, telemetry, and non-critical logs.

**At-Least-Once:** Acknowledge after successful processing. Retries on failure guarantee no message loss, but duplicates are possible. Requires idempotent consumers.

**Exactly-Once:** Transactional processing ensuring no loss and no duplicate effect. Achievable with Kafka transactions + idempotent producers, or with transactional outbox + deduplication. Expensive — use only when the cost of duplicates or loss is unacceptable (payments, inventory).

**TypeScript (SQS at-least-once — explicit ack after processing):**
```typescript
async function runConsumer(): Promise<void> {
  while (true) {
    const { Messages } = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: QUEUE_URL,
      MaxNumberOfMessages: 10,
      WaitTimeSeconds: 20,
      AttributeNames: ["ApproximateReceiveCount"],
    }));

    for (const msg of Messages ?? []) {
      const receiveCount = Number(msg.Attributes?.ApproximateReceiveCount ?? 1);
      try {
        await processEvent(JSON.parse(msg.Body!));
        // Ack AFTER successful processing (at-least-once)
        await sqs.send(new DeleteMessageCommand({
          QueueUrl: QUEUE_URL,
          ReceiptHandle: msg.ReceiptHandle!,
        }));
      } catch (err) {
        log.error("Processing failed", { err, receiveCount });
        // Do NOT delete — SQS will redeliver, then route to DLQ after maxReceiveCount
      }
    }
  }
}
```

**Java (Kafka exactly-once with transactions):**
```java
@Bean
public KafkaTransactionManager<String, String> kafkaTransactionManager(
    ProducerFactory<String, String> pf) {
  return new KafkaTransactionManager<>(pf);
}

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

The dual-write problem: writing to the database and publishing an event are two separate operations. A crash between them leaves them inconsistent. The Outbox pattern eliminates this by writing the event into an `outbox` table in the same database transaction as the state change, then relaying it to the message broker asynchronously.

**Red Flags:**
- Publishing directly to broker inside a service method alongside a DB write — crash between them = lost event or phantom event
- Outbox relay polling interval too slow — increases end-to-end latency
- Outbox table grows unbounded — no cleanup of successfully relayed events
- Outbox relay has no idempotency on the broker side — re-relay after relay crash causes duplicate publish

**TypeScript (Outbox write + relay with PostgreSQL):**
```typescript
// Step 1: Write state + event atomically in one transaction
async function placeOrder(order: NewOrder): Promise<Order> {
  return db.transaction(async (tx) => {
    const saved = await tx.insert(orders).values(order).returning().get();
    // Write event to outbox in the SAME transaction
    await tx.insert(outboxEvents).values({
      id: crypto.randomUUID(),
      aggregateType: "order",
      aggregateId: saved.id,
      eventType: "order.placed",
      payload: JSON.stringify(saved),
      createdAt: new Date(),
      relayed: false,
    });
    return saved;
  });
}

// Step 2: Relay process polls outbox and publishes to broker
async function relayOutboxEvents(): Promise<void> {
  const pending = await db
    .select()
    .from(outboxEvents)
    .where(eq(outboxEvents.relayed, false))
    .limit(100)
    .for("update skip locked");   // Prevents concurrent relay from picking the same rows

  for (const evt of pending) {
    await broker.publish(evt.eventType, evt.payload);
    await db.update(outboxEvents)
      .set({ relayed: true, relayedAt: new Date() })
      .where(eq(outboxEvents.id, evt.id));
  }
}
```

**Java (Spring + JPA Outbox):**
```java
@Service
@Transactional
public class OrderService {

    private final OrderRepository orders;
    private final OutboxRepository outbox;

    public Order place(CreateOrderCommand cmd) {
        Order order = orders.save(new Order(cmd));
        outbox.save(OutboxEvent.of("order.placed", order.getId(), order));
        // Both writes commit or both roll back — dual-write safety guaranteed
        return order;
    }
}

@Scheduled(fixedDelay = 1000)
@Transactional
public void relayPendingEvents() {
    outboxRepository.findUnrelayed(PageRequest.of(0, 50))
        .forEach(evt -> {
            kafkaTemplate.send(evt.getEventType(), evt.getAggregateId(), evt.getPayload());
            evt.markRelayed();
        });
}
```

Cross-reference: `event-sourcing-cqrs-patterns` — the Event Store is the authoritative outbox when event sourcing is in use; no separate outbox table needed.

---

### 5. Dead Letter Queues and Poison Pill Messages

A Dead Letter Queue (DLQ) captures messages that cannot be successfully processed after exhausting retry attempts. Without a DLQ, poison pill messages (malformed, schema-mismatched, or triggering bugs) block the queue indefinitely or cause infinite retry loops.

**Red Flags:**
- No retry limit — a poison pill retried indefinitely starves valid messages (especially critical in ordered queues)
- DLQ exists but no alert on DLQ depth — messages silently accumulate, masking data loss
- Consumer catches all exceptions and acks — data loss with no audit trail
- No replay tooling for DLQ — events stuck forever with no recovery path

**TypeScript (RabbitMQ — DLQ via dead-letter-exchange):**
```typescript
// Channel setup: bind queue to DLX for automatic DLQ routing
await channel.assertExchange("orders.dlx", "direct", { durable: true });
await channel.assertQueue("orders.dlq", { durable: true });
await channel.bindQueue("orders.dlq", "orders.dlx", "orders");

await channel.assertQueue("orders", {
  durable: true,
  arguments: {
    "x-dead-letter-exchange": "orders.dlx",
    "x-dead-letter-routing-key": "orders",
    "x-message-ttl": 30_000,       // Move to DLQ after 30s if unacked
    "x-max-delivery-count": 3,     // Move to DLQ after 3 failures
  },
});

// Consumer: only nack(requeue=false) to route to DLQ; never silently drop
channel.consume("orders", async (msg) => {
  if (!msg) return;
  try {
    await processOrder(JSON.parse(msg.content.toString()));
    channel.ack(msg);
  } catch (err) {
    const deliveryCount = (msg.properties.headers?.["x-death"]?.[0]?.count ?? 0) + 1;
    log.error("Order processing failed", { err, deliveryCount });
    // nack with requeue=false sends to DLX after maxDeliveryCount
    channel.nack(msg, false, deliveryCount < 3);
  }
});
```

**Go (Kafka — manual DLQ routing):**
```go
func consume(ctx context.Context, reader *kafka.Reader, dlqWriter *kafka.Writer) {
    for {
        msg, err := reader.FetchMessage(ctx)
        if err != nil { break }

        if processErr := handleMessage(msg); processErr != nil {
            log.Printf("failed to process %s: %v", msg.Key, processErr)
            // Route to DLQ topic instead of blocking the partition
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
                continue // Do NOT commit offset — will retry
            }
        }
        reader.CommitMessages(ctx, msg)
    }
}
```

Cross-reference: `microservices-resilience-patterns` — Circuit Breaker and Retry patterns that complement DLQ for transient vs. permanent failures.

---

### 6. Kafka Partition Design and Consumer Groups

Kafka's scalability and ordering guarantees hinge on partition design. A partition is the unit of parallelism and ordering. Messages within a partition are totally ordered; messages across partitions are not.

**Key Rules:**
- Partition count determines maximum consumer parallelism. More consumers than partitions = idle consumers.
- Partition key determines which partition a message lands in. Related messages must use the same key to guarantee ordering.
- Consumer groups provide independent consumption — each group gets its own offset per partition.
- Rebalancing (adding/removing consumers) causes brief processing pauses; minimize with sticky assignors.

**Red Flags:**
- All messages sent with a `null` partition key — round-robin distribution breaks ordering for related events
- Partition count set to 1 — single-threaded throughput, no parallelism
- Single consumer group for two logically independent services — they share offsets and interfere
- Hot partition — one key (e.g., a viral user) overwhelms one partition while others sit idle
- Retaining offsets of committed but unprocessed messages — crashes cause data loss

**Java (Kafka producer with partition key):**
```java
@Service
public class OrderEventProducer {

    private final KafkaTemplate<String, OrderEvent> kafkaTemplate;

    public void publishOrderEvent(OrderEvent event) {
        // Use orderId as partition key — all events for one order go to the same partition
        // ensuring strict ordering per order
        var record = new ProducerRecord<>("order-events", event.getOrderId(), event);
        kafkaTemplate.send(record)
            .addCallback(
                result -> log.debug("Published offset={}", result.getRecordMetadata().offset()),
                ex -> log.error("Publish failed for order={}", event.getOrderId(), ex)
            );
    }
}
```

**TypeScript (consumer group with explicit partition assignment):**
```typescript
import { Kafka } from "kafkajs";

const kafka = new Kafka({ clientId: "inventory-service", brokers: [process.env.KAFKA_BROKER!] });

// Each service has its own consumer group — independent offsets
const consumer = kafka.consumer({ groupId: "inventory-service-group" });

await consumer.connect();
await consumer.subscribe({ topic: "order-events", fromBeginning: false });

await consumer.run({
  partitionsConsumedConcurrently: 4,   // Process up to 4 partitions in parallel
  eachMessage: async ({ topic, partition, message }) => {
    const event = JSON.parse(message.value!.toString()) as OrderEvent;
    log.info("Processing", { partition, offset: message.offset, orderId: event.orderId });
    await inventoryService.reserve(event);
    // kafkajs commits offsets automatically after eachMessage resolves
  },
});
```

**Go (Sarama consumer group — rebalance handling):**
```go
type OrderConsumerGroup struct{ svc OrderService }

func (c *OrderConsumerGroup) Setup(kafka.ConsumerGroupSession) error   { return nil }
func (c *OrderConsumerGroup) Cleanup(kafka.ConsumerGroupSession) error { return nil }

func (c *OrderConsumerGroup) ConsumeClaim(session kafka.ConsumerGroupSession, claim kafka.ConsumerGroupClaim) error {
    for msg := range claim.Messages() {
        var event OrderEvent
        if err := json.Unmarshal(msg.Value, &event); err != nil {
            log.Printf("malformed message at offset %d: %v", msg.Offset, err)
            session.MarkMessage(msg, "") // ack to avoid blocking; route externally if needed
            continue
        }
        if err := c.svc.Process(session.Context(), event); err != nil {
            return err // Stop claiming — trigger rebalance and retry
        }
        session.MarkMessage(msg, "")
    }
    return nil
}
```

---

### 7. Message Ordering and Idempotency

Distributed systems deliver messages out of order (network reordering, retries, parallel consumers). Design consumers to be both idempotent and order-tolerant unless strict ordering is enforced by infrastructure (e.g., a single Kafka partition per entity).

**Idempotency strategies:**
1. **Idempotency key:** Track processed message IDs in a store; skip duplicates.
2. **Conditional update:** `UPDATE ... WHERE version = expectedVersion` — reject stale updates.
3. **Event deduplication window:** Accept duplicate within a TTL window; discard thereafter.

**Ordering strategies:**
1. **Partition by entity ID:** All events for a given entity go to the same Kafka partition.
2. **Sequence numbers:** Consumers detect gaps and buffer out-of-order messages.
3. **Optimistic concurrency:** State updates carry expected sequence; reject if sequence mismatch.

**Red Flags:**
- No idempotency guard with at-least-once delivery — inevitable duplicates corrupt state
- Consumers across multiple partitions assuming global order — only partition-level order is guaranteed
- Sequence numbers used but gaps not handled — out-of-order processing silently skips events

**TypeScript (idempotency with conditional DB update):**
```typescript
interface InventoryEvent {
  messageId: string;
  productId: string;
  sequenceNumber: number;
  delta: number;
}

async function applyInventoryEvent(event: InventoryEvent): Promise<void> {
  // Conditional update: only applies if this is the next expected sequence
  const result = await db
    .update(inventory)
    .set({
      quantity: sql`quantity + ${event.delta}`,
      lastSequence: event.sequenceNumber,
    })
    .where(
      and(
        eq(inventory.productId, event.productId),
        eq(inventory.lastSequence, event.sequenceNumber - 1)
      )
    );

  if (result.rowsAffected === 0) {
    // Either duplicate (already at this sequence) or out-of-order (gap detected)
    const current = await db.select().from(inventory)
      .where(eq(inventory.productId, event.productId)).get();
    if (current && current.lastSequence >= event.sequenceNumber) {
      log.info("Duplicate event discarded", { messageId: event.messageId });
    } else {
      log.warn("Out-of-order event, buffering", { messageId: event.messageId });
      await eventBuffer.store(event);
    }
  }
}
```

**Java (idempotency key with deduplication table):**
```java
@Transactional
public void handlePaymentEvent(PaymentEvent event) {
    // Check idempotency key before any state mutation
    if (processedEventRepository.existsById(event.getEventId())) {
        log.debug("Duplicate event skipped: {}", event.getEventId());
        return;
    }

    paymentService.apply(event);

    // Record the event ID atomically with the state change
    processedEventRepository.save(
        new ProcessedEvent(event.getEventId(), Instant.now())
    );
}
```

Cross-reference: `event-sourcing-cqrs-patterns` — Event Store append semantics naturally provide idempotency via sequence position; no separate deduplication table needed when event sourcing is in use.

---

### 8. Backpressure in Messaging Systems

Backpressure is the mechanism by which a slow consumer signals a fast producer to reduce its send rate. Without backpressure, fast producers fill in-memory queues, causing OOM crashes or unbounded latency spikes.

**Backpressure mechanisms:**
- **Pull-based consumption (Kafka):** Consumer controls its own fetch rate — inherently backpressure-safe.
- **Prefetch limit (AMQP):** `basicQos(prefetchCount)` limits unacknowledged messages in-flight per consumer.
- **Rate limiting at producer:** Token bucket or semaphore limits send rate.
- **Reactive Streams:** `Publisher.request(n)` — consumer demands exactly `n` items at a time.

**Red Flags:**
- `prefetchCount = 0` (unlimited) on a slow RabbitMQ consumer — broker dumps all messages into consumer memory
- Buffering messages in-memory in a consumer without a cap — heap grows until OOM
- Producer publishing faster than consumers can process without any feedback loop
- Ignoring Kafka lag metrics — consumer group falling behind without alerting

**TypeScript (RabbitMQ prefetch + bounded in-memory buffer):**
```typescript
await channel.prefetch(10);  // Max 10 unacknowledged messages per consumer

const processingQueue = new PQueue({ concurrency: 5 });  // Bounded concurrency

channel.consume("orders", (msg) => {
  if (!msg) return;
  processingQueue.add(async () => {
    try {
      await processOrder(JSON.parse(msg.content.toString()));
      channel.ack(msg);
    } catch (err) {
      log.error("Processing failed", err);
      channel.nack(msg, false, false);  // Send to DLQ
    }
  });
});
```

**Go (channel-based backpressure with bounded worker pool):**
```go
func startWorkerPool(ctx context.Context, reader *kafka.Reader, workerCount int) {
    work := make(chan kafka.Message, workerCount*2)  // Bounded buffer

    // Start fixed worker pool
    var wg sync.WaitGroup
    for i := 0; i < workerCount; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for msg := range work {
                if err := handleMessage(ctx, msg); err != nil {
                    log.Printf("worker error: %v", err)
                }
            }
        }()
    }

    // Reader blocks when channel is full — natural backpressure
    for {
        msg, err := reader.FetchMessage(ctx)
        if err != nil { break }
        work <- msg  // Blocks if workers are saturated
        reader.CommitMessages(ctx, msg)
    }
    close(work)
    wg.Wait()
}
```

Cross-reference: `data-pipeline-patterns` — Streaming backpressure with Reactive Streams and flow control in data pipeline contexts.

---

### 9. Messaging Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Fire-and-Forget without DLQ** | Publishing a message with no retry, no DLQ, no ack confirmation | Add DLQ + monitoring; use at-least-once delivery with ack |
| **Unbounded Queue** | Queue depth grows without a consumer keeping pace | Implement backpressure; alert on queue depth; add consumers |
| **Poison Pill** | A malformed message blocks queue indefinitely with infinite retries | Set retry limit; route to DLQ; add schema validation at publish time |
| **Chatty Messaging** | Sending hundreds of tiny messages where one batch would do | Batch related events; use compacted topics for state |
| **Dual-Write Without Outbox** | Writing to DB and broker in separate operations | Use Transactional Outbox or event sourcing |
| **Shared Consumer Group** | Two logically independent services share one consumer group | Each service must have its own group ID |
| **Missing Idempotency** | No deduplication guard with at-least-once delivery | Add idempotency key check before every state mutation |
| **Global Ordering Assumption** | Assuming total order across partitions or queues | Enforce ordering only where needed: single partition per entity |
| **No Observability** | No metrics on queue depth, consumer lag, or DLQ depth | Instrument all queues; alert on lag, DLQ growth, and consumer errors |

**Poison Pill — TypeScript fix:**
```typescript
// WRONG: Retry forever — blocks the partition
async function badConsumer(msg: Message) {
  while (true) {
    try { await process(msg); break; }
    catch { /* keep retrying */ }
  }
}

// CORRECT: Bounded retries → DLQ on exhaustion
async function goodConsumer(msg: Message, attempt: number): Promise<void> {
  try {
    await process(msg);
    await ack(msg);
  } catch (err) {
    if (attempt >= 3) {
      log.error("Routing to DLQ after max attempts", { msgId: msg.id, err });
      await dlq.publish(msg, { reason: String(err), attempt });
      await ack(msg);  // Ack original to unblock the queue
    } else {
      await nack(msg, { requeue: true, delay: 2 ** attempt * 1000 });
    }
  }
}
```

**Dual-Write without Outbox — Java fix:**
```java
// WRONG: Two separate operations — crash between them = inconsistency
@Transactional
public void placeOrderWrong(Order order) {
    orderRepository.save(order);
    // Crash here = order saved but event never published
    kafkaTemplate.send("order-events", order.getId(), order);
}

// CORRECT: Outbox within transaction — relay handles broker publish
@Transactional
public void placeOrderCorrect(Order order) {
    orderRepository.save(order);
    outboxRepository.save(OutboxEvent.of("order.placed", order.getId(), order));
    // Both succeed or both rollback — broker publish happens in relay
}
```

---

## Cross-References

- `microservices-resilience-patterns` — Retry, Circuit Breaker, and Bulkhead patterns that complement at-least-once delivery and DLQ routing
- `event-sourcing-cqrs-patterns` — Event Store as authoritative outbox; CQRS projections as pub/sub consumers
- `data-pipeline-patterns` — Streaming backpressure, windowed aggregation, and exactly-once semantics in data pipelines
- `observability-patterns` — Queue depth, consumer lag, and DLQ depth instrumentation; alerting thresholds
- `concurrency-patterns` — Producer-Consumer with bounded channels; async task coordination
