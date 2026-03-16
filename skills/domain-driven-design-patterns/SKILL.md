---
name: domain-driven-design-patterns
description: Use when designing or reviewing domain models — covers Bounded Contexts, Context Mapping, Aggregate Root, Value Objects vs Entities, Domain Events, Ubiquitous Language, Repository pattern, Domain vs Application Services, and DDD anti-patterns (anemic domain model, feature envy) with examples in TypeScript, Java, Go, and Python
---

# Domain-Driven Design Patterns

## Overview

Domain-Driven Design (DDD) aligns the software model with the business domain. The goal is code that domain experts can read, invariants enforced at the model boundary, and explicit seams between subsystems that evolve independently.

**When to use:** Designing a new bounded context; reviewing a domain model for anemia or leaking invariants; evaluating how two services should integrate; any time business rules are scattered across service layers instead of living in the domain.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Bounded Context | Explicit boundary around a coherent domain model | Same concept named differently in two subsystems with no translation layer |
| Context Mapping | Named relationship between bounded contexts | Direct DB joins across context boundaries; shared mutable tables |
| Aggregate Root | Cluster of objects treated as one unit for writes | Direct mutation of child entities bypassing the root |
| Value Object | Immutable, identity-free; equality by attributes | Mutable DTO used as a domain concept; comparing Money by reference |
| Entity | Mutable over time; identity by ID | Equality checked by comparing all fields instead of ID |
| Domain Event | Fact that something happened in the domain | Calling another context's service directly; tight coupling across contexts |
| Ubiquitous Language | Single shared vocabulary between devs and domain experts | Code uses `user` where the domain says `member`; translation scattered everywhere |
| Repository (DDD) | Collection-oriented abstraction over persistence | `UserRepository.findActiveByEmailSortedByLoginDesc` — query leaks into domain |
| Domain Service | Stateless operation that does not belong to one entity | Business logic living in application/controller layers |
| Application Service | Orchestrates use cases; no domain logic | Domain invariants enforced in a controller or middleware |

---

## Patterns in Detail

### 1. Bounded Contexts and Context Mapping

A **Bounded Context** is an explicit linguistic boundary within which a single domain model applies. The same word can mean different things in different contexts — a `Customer` in billing is not the same object as a `Customer` in shipping.

**Red Flags:**
- Two teams share a single database table with no translation — one team's migration breaks the other
- A `User` object is imported directly from another service instead of being translated at the boundary
- No explicit context map exists; team members argue over what "order" means

#### Shared Kernel

Both contexts share a small, explicitly versioned subset of the model. Changes require agreement from both teams.

**When to use:** Two closely related contexts need to share a core concept (e.g., `Money`, `Currency`) without duplicating it.

**TypeScript — shared kernel as a published package:**
```typescript
// @company/shared-kernel — owned jointly, versioned strictly
export class Money {
  constructor(readonly amount: number, readonly currency: string) {
    if (amount < 0) throw new Error('Money amount must be non-negative');
    if (!currency) throw new Error('Currency required');
  }
  add(other: Money): Money {
    if (this.currency !== other.currency) throw new Error('Currency mismatch');
    return new Money(this.amount + other.amount, this.currency);
  }
  equals(other: Money): boolean {
    return this.amount === other.amount && this.currency === other.currency;
  }
}
```

#### Anti-Corruption Layer (ACL)

Translates an external or upstream model into the local bounded context's model. Prevents foreign concepts from polluting the local domain.

**When to use:** Integrating with a legacy system, a third-party API, or an upstream context you do not own.

**TypeScript:**
```typescript
// External model (legacy CRM)
interface CrmContact { contactId: string; fullName: string; emailAddress: string; }

// Local domain model
interface Customer { id: string; name: string; email: string; }

// ACL — translates at the boundary, never imported inside the domain
class CrmAntiCorruptionLayer {
  toCustomer(contact: CrmContact): Customer {
    return {
      id: contact.contactId,
      name: contact.fullName,
      email: contact.emailAddress,
    };
  }
}
```

**Java:**
```java
// ACL lives in infrastructure layer
public class LegacyOrderTranslator {
    public Order toDomain(LegacyOrderRecord record) {
        return Order.reconstitute(
            new OrderId(record.getOrderNo()),
            Money.of(record.getTotalCents(), Currency.getInstance("USD")),
            mapStatus(record.getStatusCode())
        );
    }
    private OrderStatus mapStatus(int code) {
        return switch (code) {
            case 1 -> OrderStatus.PENDING;
            case 2 -> OrderStatus.CONFIRMED;
            default -> throw new IllegalArgumentException("Unknown status: " + code);
        };
    }
}
```

#### Customer-Supplier

An upstream context (supplier) produces data consumed by a downstream context (customer). The supplier owns the contract; the customer adapts.

**Red Flags:**
- Customer directly queries the supplier's database
- Contract changes are not versioned — downstream breaks silently
- No conformist layer or ACL on the downstream side

---

### 2. Aggregate Root and Invariant Enforcement

An **Aggregate** is a cluster of domain objects that must be treated as a unit for writes. The **Aggregate Root** is the single entry point — all mutations go through it, ensuring invariants are never violated.

**Red Flags:**
- External code calls `order.lineItems.push(item)` directly — bypasses root's validation
- Repository saves a child entity directly (`lineItemRepo.save(item)`) instead of the root
- Aggregate spans multiple database transactions — consistency window is too wide
- Invariant checked in application service instead of inside the aggregate

**TypeScript:**
```typescript
// BEFORE — invariant enforcement scattered in application service
class OrderService {
  addItem(order: Order, item: LineItem) {
    if (order.status !== 'PENDING') throw new Error('Cannot modify confirmed order');
    if (order.lineItems.length >= 50) throw new Error('Too many items');
    order.lineItems.push(item);  // direct mutation — bypasses root
  }
}

// AFTER — aggregate root owns the invariant
class Order {
  private _lineItems: LineItem[] = [];
  private _status: OrderStatus = OrderStatus.PENDING;

  get lineItems(): ReadonlyArray<LineItem> { return this._lineItems; }
  get status(): OrderStatus { return this._status; }

  addItem(item: LineItem): void {
    if (this._status !== OrderStatus.PENDING) {
      throw new DomainError('Cannot modify a non-pending order');
    }
    if (this._lineItems.length >= 50) {
      throw new DomainError('Order cannot have more than 50 line items');
    }
    this._lineItems = [...this._lineItems, item];
  }

  confirm(): void {
    if (this._lineItems.length === 0) throw new DomainError('Cannot confirm empty order');
    this._status = OrderStatus.CONFIRMED;
  }
}
```

**Java:**
```java
public final class Order {
    private final OrderId id;
    private final List<LineItem> lineItems = new ArrayList<>();
    private OrderStatus status = OrderStatus.PENDING;

    public void addItem(LineItem item) {
        if (status != OrderStatus.PENDING)
            throw new DomainException("Order is not modifiable in status: " + status);
        if (lineItems.size() >= 50)
            throw new DomainException("Order item limit exceeded");
        lineItems.add(Objects.requireNonNull(item));
    }

    public void confirm() {
        if (lineItems.isEmpty()) throw new DomainException("Cannot confirm empty order");
        this.status = OrderStatus.CONFIRMED;
    }

    public List<LineItem> getLineItems() { return Collections.unmodifiableList(lineItems); }
}
```

---

### 3. Value Objects vs Entities

**Entity:** Has a unique identity that persists over time. Two entities with the same data are still different objects if their IDs differ.

**Value Object:** Has no identity. Two value objects with the same attributes are interchangeable. Must be immutable.

**Red Flags:**
- `Money` or `Address` compared with `==` (reference equality) instead of structural equality
- A `Money` object mutated in place: `price.amount += tax`
- An entity compared by all fields in `equals()` instead of by ID
- A DTO passed around as if it were a domain value object (no validation, no behavior)

**TypeScript — Value Object:**
```typescript
// BEFORE — primitive obsession; no validation, no behavior
function applyDiscount(price: number, rate: number): number {
  return price * (1 - rate);
}

// AFTER — Value Object encapsulates behavior and invariants
class Money {
  constructor(readonly amount: number, readonly currency: string) {
    if (amount < 0) throw new DomainError('Amount cannot be negative');
    if (!['USD', 'EUR', 'GBP'].includes(currency)) throw new DomainError(`Unsupported currency: ${currency}`);
    Object.freeze(this);
  }
  applyDiscount(rate: number): Money {
    if (rate < 0 || rate > 1) throw new DomainError('Discount rate must be between 0 and 1');
    return new Money(Math.round(this.amount * (1 - rate) * 100) / 100, this.currency);
  }
  add(other: Money): Money {
    if (this.currency !== other.currency) throw new DomainError('Currency mismatch');
    return new Money(this.amount + other.amount, this.currency);
  }
  equals(other: Money): boolean {
    return this.amount === other.amount && this.currency === other.currency;
  }
}
```

**Go — Value Object as struct (no pointer equality):**
```go
type Money struct {
    Amount   int    // stored as cents
    Currency string
}

func NewMoney(amount int, currency string) (Money, error) {
    if amount < 0 {
        return Money{}, errors.New("amount must be non-negative")
    }
    if currency == "" {
        return Money{}, errors.New("currency required")
    }
    return Money{Amount: amount, Currency: currency}, nil
}

func (m Money) Add(other Money) (Money, error) {
    if m.Currency != other.Currency {
        return Money{}, fmt.Errorf("currency mismatch: %s vs %s", m.Currency, other.Currency)
    }
    return Money{Amount: m.Amount + other.Amount, Currency: m.Currency}, nil
}
```

**Python — Value Object with dataclass:**
```python
from dataclasses import dataclass
from typing import ClassVar

@dataclass(frozen=True)  # frozen=True enforces immutability
class Money:
    amount: int  # in cents
    currency: str
    SUPPORTED: ClassVar[set] = {'USD', 'EUR', 'GBP'}

    def __post_init__(self):
        if self.amount < 0:
            raise ValueError('Amount must be non-negative')
        if self.currency not in self.SUPPORTED:
            raise ValueError(f'Unsupported currency: {self.currency}')

    def add(self, other: 'Money') -> 'Money':
        if self.currency != other.currency:
            raise ValueError('Currency mismatch')
        return Money(self.amount + other.amount, self.currency)
```

---

### 4. Domain Events and Ubiquitous Language

**Domain Events** capture something meaningful that happened in the domain. They decouple side effects (sending email, updating read models) from the core business operation, and make implicit requirements explicit.

**Ubiquitous Language** is the shared vocabulary between developers and domain experts. Every class, method, and variable name should use the domain's own terms.

**Red Flags (Domain Events):**
- Application service calls `emailService.send()` directly after saving an order — tight coupling, hard to test
- Domain state changed but no event raised — downstream effects handled with polling or comments
- Events carry mutable objects instead of being immutable snapshots

**Red Flags (Ubiquitous Language):**
- Code says `user` when the domain says `member` or `subscriber`
- Method named `process()` when the domain term is `fulfill()` or `dispatch()`
- Translation from domain terms happening inside the domain layer rather than at its boundary

**TypeScript — Domain Events:**
```typescript
// Value Object: an immutable event snapshot
interface DomainEvent { readonly occurredAt: Date; }

class OrderConfirmed implements DomainEvent {
  readonly occurredAt = new Date();
  constructor(
    readonly orderId: string,
    readonly customerId: string,
    readonly totalAmount: Money,
  ) { Object.freeze(this); }
}

// Aggregate raises events; application service dispatches them
class Order {
  private _events: DomainEvent[] = [];

  confirm(): void {
    if (this._lineItems.length === 0) throw new DomainError('Cannot confirm empty order');
    this._status = OrderStatus.CONFIRMED;
    this._events.push(new OrderConfirmed(this._id, this._customerId, this.total()));
  }

  pullEvents(): DomainEvent[] {
    const events = [...this._events];
    this._events = [];
    return events;
  }
}

// Application Service — orchestrates, dispatches events, no domain logic
class ConfirmOrderUseCase {
  constructor(
    private readonly orders: OrderRepository,
    private readonly eventBus: DomainEventBus,
  ) {}

  async execute(orderId: string): Promise<void> {
    const order = await this.orders.findById(orderId);
    if (!order) throw new NotFoundError(`Order not found: ${orderId}`);
    order.confirm();
    await this.orders.save(order);
    await this.eventBus.publishAll(order.pullEvents());
  }
}
```

**Java — Domain Events with Spring:**
```java
public class OrderConfirmed {
    private final String orderId;
    private final Instant occurredAt = Instant.now();
    // constructor, getters omitted for brevity
}

// Handler in a different bounded context, decoupled via event
@Component
public class SendOrderConfirmationEmail {
    @EventListener
    public void on(OrderConfirmed event) {
        emailService.sendConfirmation(event.getOrderId());
    }
}
```

---

### 5. Repository Pattern in DDD Context

The DDD **Repository** presents a collection-like interface over a set of aggregates. It hides persistence mechanics entirely — the domain does not know if data lives in PostgreSQL, MongoDB, or memory.

**Red Flags:**
- Repository method named `findActiveByEmailSortedByLoginDescWithPagination` — query semantics leak into domain
- Application service constructs SQL strings — no abstraction
- Repository returns a DTO or ORM entity instead of a domain aggregate
- `UserRepository` has a `save(lineItem)` method — saving a child directly

**TypeScript:**
```typescript
// Domain interface — collection-like, no persistence details
interface OrderRepository {
  findById(id: string): Promise<Order | null>;
  findByCustomer(customerId: string): Promise<Order[]>;
  save(order: Order): Promise<void>;
  nextId(): string;
}

// Infrastructure implementation — hidden behind the interface
class PostgresOrderRepository implements OrderRepository {
  async findById(id: string): Promise<Order | null> {
    const row = await this.db.query('SELECT * FROM orders WHERE id = $1', [id]);
    return row ? this.toDomain(row) : null;
  }
  async save(order: Order): Promise<void> {
    await this.db.transaction(async (tx) => {
      await tx.upsert('orders', this.toRecord(order));
      for (const item of order.lineItems) {
        await tx.upsert('order_line_items', this.toLineItemRecord(item, order.id));
      }
    });
  }
  nextId(): string { return crypto.randomUUID(); }
  private toDomain(row: OrderRow): Order { /* mapping logic */ return {} as Order; }
  private toRecord(order: Order): OrderRow { /* mapping logic */ return {} as OrderRow; }
  private toLineItemRecord(item: LineItem, orderId: string): LineItemRow { return {} as LineItemRow; }
}
```

**Go:**
```go
// Repository interface — domain package
type OrderRepository interface {
    FindByID(ctx context.Context, id OrderID) (*Order, error)
    Save(ctx context.Context, order *Order) error
    NextID() OrderID
}

// Infrastructure implementation — separate package
type pgOrderRepository struct{ db *sql.DB }

func (r *pgOrderRepository) FindByID(ctx context.Context, id OrderID) (*Order, error) {
    row := r.db.QueryRowContext(ctx, `SELECT id, customer_id, status, total_cents FROM orders WHERE id = $1`, id)
    return scanOrder(row)
}
```

---

### 6. Domain Services vs Application Services

**Domain Service:** Stateless, encapsulates a domain operation that does not belong naturally to a single entity or value object. Lives in the domain layer.

**Application Service (Use Case):** Orchestrates the use case — loads aggregates from repositories, calls domain logic, publishes events, handles transactions. Contains NO domain logic itself.

**Red Flags:**
- Business rule (e.g., pricing calculation) in a REST controller
- Domain service with injected `HttpClient` or `EmailSender` — infrastructure in the domain
- Application service containing `if` branches expressing business rules
- `OrderService` that does everything (load, validate business rules, persist, send email) — mixed responsibilities

**TypeScript — Domain Service:**
```typescript
// Domain Service — pure domain logic, no infrastructure
class PricingService {
  calculateTotal(items: LineItem[], discountCode: DiscountCode | null): Money {
    const subtotal = items.reduce(
      (sum, item) => sum.add(item.unitPrice.multiply(item.quantity)),
      Money.zero('USD'),
    );
    if (!discountCode) return subtotal;
    return subtotal.applyDiscount(discountCode.rate);
  }
}

// Application Service — orchestration only
class PlaceOrderUseCase {
  constructor(
    private readonly orders: OrderRepository,
    private readonly pricing: PricingService,
    private readonly eventBus: DomainEventBus,
  ) {}

  async execute(cmd: PlaceOrderCommand): Promise<string> {
    const items = cmd.lineItems.map(i => new LineItem(i.sku, i.qty, new Money(i.priceCents, 'USD')));
    const discount = cmd.discountCode ? DiscountCode.of(cmd.discountCode) : null;
    const total = this.pricing.calculateTotal(items, discount);
    const order = Order.place(this.orders.nextId(), cmd.customerId, items, total);
    await this.orders.save(order);
    await this.eventBus.publishAll(order.pullEvents());
    return order.id;
  }
}
```

**Python — Domain Service:**
```python
# Domain service — no I/O, no infrastructure
class TransferService:
    def transfer(self, source: Account, target: Account, amount: Money) -> None:
        if source.balance < amount:
            raise InsufficientFundsError(f'Balance {source.balance} < transfer {amount}')
        source.debit(amount)
        target.credit(amount)

# Application service — orchestration, transaction boundary
class TransferFundsUseCase:
    def __init__(self, accounts: AccountRepository, events: DomainEventBus,
                 transfer_service: TransferService) -> None:
        self._accounts = accounts
        self._events = events
        self._transfer_service = transfer_service

    def execute(self, cmd: TransferFundsCommand) -> None:
        source = self._accounts.find_by_id(cmd.source_id)
        target = self._accounts.find_by_id(cmd.target_id)
        if not source or not target:
            raise NotFoundError('Account not found')
        self._transfer_service.transfer(source, target, Money(cmd.amount_cents, cmd.currency))
        self._accounts.save(source)
        self._accounts.save(target)
        for event in source.pull_events() + target.pull_events():
            self._events.publish(event)
```

---

### 7. DDD Anti-Patterns

#### Anemic Domain Model

Classes that hold data but have no behavior. All logic lives in service layers. The domain model becomes a glorified struct.

**Red Flags:**
- Every class is a bag of getters/setters with no methods
- Business rules live in `OrderService`, `UserService`, `ProductService` instead of in the entities
- Any caller can mutate any field at any time — no invariant enforcement

**TypeScript — Anemic vs Rich:**
```typescript
// WRONG — Anemic Domain Model
class Order {
  id: string = '';
  status: string = '';
  lineItems: LineItem[] = [];
  total: number = 0;
}

class OrderService {
  confirm(order: Order): void {
    // Business rules scattered here, not in Order
    if (order.lineItems.length === 0) throw new Error('Empty');
    if (order.status !== 'PENDING') throw new Error('Not pending');
    order.status = 'CONFIRMED';  // direct mutation from outside
  }
}

// CORRECT — Rich Domain Model: invariants live on the aggregate
class Order {
  private _status = OrderStatus.PENDING;
  private _lineItems: readonly LineItem[] = [];

  confirm(): void {
    if (this._lineItems.length === 0) throw new DomainError('Cannot confirm empty order');
    if (this._status !== OrderStatus.PENDING) throw new DomainError('Already confirmed');
    this._status = OrderStatus.CONFIRMED;
  }
}
```

#### Feature Envy

A method that accesses data from another object more than its own — a symptom that the logic belongs in the other class.

**Red Flags:**
- `discountService.calculateFor(order)` calls `order.getCustomer().getTier().getRate()` and `order.getLineItems()` — it knows too much about `Order`
- The method would be trivially simpler if moved to the object it queries

**Java — Feature Envy fix:**
```java
// BEFORE — DiscountCalculator envies Order
public class DiscountCalculator {
    public Money calculate(Order order) {
        CustomerTier tier = order.getCustomer().getTier();
        int itemCount = order.getLineItems().size();
        double rate = tier == CustomerTier.GOLD ? 0.15 : itemCount > 10 ? 0.05 : 0.0;
        return order.getSubtotal().multiply(rate);
    }
}

// AFTER — move discount logic onto Order, where the data lives
public class Order {
    public Money calculateDiscount() {
        double rate = this.customer.tier() == CustomerTier.GOLD ? 0.15
                    : this.lineItems.size() > 10 ? 0.05 : 0.0;
        return this.subtotal().multiply(rate);
    }
}
```

---

## DDD Anti-Pattern Summary

| Anti-Pattern | Description | Fix |
|---|---|---|
| **Anemic Domain Model** | Entities are data bags; logic in services | Move behavior and invariants into the aggregate |
| **Feature Envy** | Method knows too much about another object's internals | Move the method to the object it queries |
| **Leaking Invariants** | Business rules enforced in application or infrastructure layer | Push invariants down into the aggregate root |
| **God Aggregate** | One aggregate owns everything in the context | Split by transaction boundary; each aggregate handles one consistency unit |
| **Shared Mutable Table** | Two bounded contexts write to the same DB table | Introduce an ACL and event-based integration |
| **Missing Ubiquitous Language** | Code terms differ from domain expert terms | Rename to match domain vocabulary; update continuously |
| **Persistence-Aware Domain** | Entity extends ORM base class; annotations in domain layer | Use a separate ORM entity; map in infrastructure layer |

---

## Cross-References

- `error-handling-patterns` — DomainError hierarchy: type domain errors explicitly so application services can handle them correctly
- `concurrency-patterns` — Optimistic locking on aggregates: version fields prevent lost updates when multiple processes modify the same aggregate
- `repository-patterns` — Unit of Work pattern: coordinate saves of multiple aggregates in a single transaction
- `event-driven-patterns` — Outbox pattern: reliably publish domain events alongside aggregate saves without two-phase commit
