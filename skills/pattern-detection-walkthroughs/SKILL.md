---
name: pattern-detection-walkthroughs
description: Use when you need end-to-end examples of detecting a code smell, identifying the underlying anti-pattern, selecting a refactoring technique, and applying the appropriate design pattern — each walkthrough traces the full diagnostic flow with before/after TypeScript code
---

# Pattern Detection Walkthroughs

## Overview

Each walkthrough follows a four-step diagnostic flow:

1. **Smell Detection** — identify the surface symptom (`detect-code-smells`)
2. **Anti-Pattern Check** — confirm the structural problem (`anti-patterns-catalog`)
3. **Refactoring Selection** — choose the move from the refactor skills
4. **Design Pattern** — apply a pattern to prevent recurrence

---

## Walkthrough 1: God Class → Extract Class + Facade

### Step 1 — Smell Detection (`detect-code-smells`)

Large Class / God Class: one class with 15+ methods across auth, profiles, email, and billing.

```typescript
// BEFORE: UserManager does everything
class UserManager {
  private db: Database;
  private mailer: Mailer;
  private stripe: StripeClient;

  login(email: string, password: string): Session { /* ... */ }
  logout(sessionId: string): void { /* ... */ }
  updateProfile(userId: string, data: ProfileData): User { /* ... */ }
  deleteAccount(userId: string): void { /* ... */ }
  sendWelcomeEmail(userId: string): void { /* ... */ }
  sendInvoice(userId: string, invoiceId: string): void { /* ... */ }
  createSubscription(userId: string, plan: string): Subscription { /* ... */ }
  processRefund(userId: string, amount: number): void { /* ... */ }
  // ... 8 more methods
}
```

Triggers: 15+ methods, 4 responsibility clusters, 3 injected external services.

### Step 2 — Anti-Pattern Check (`anti-patterns-catalog`)

**God Object** — changes to billing break auth; every developer edits the same 300-line file.

### Step 3 — Refactoring (`refactor-moving-features`)

Extract Class — one class per responsibility cluster.

```typescript
// AFTER: focused services
class AuthService {
  constructor(private db: Database) {}
  login(email: string, password: string): Session { /* ... */ }
  logout(sessionId: string): void { /* ... */ }
}

class ProfileService {
  constructor(private db: Database) {}
  updateProfile(userId: string, data: ProfileData): User { /* ... */ }
  deleteAccount(userId: string): void { /* ... */ }
}

class NotificationService {
  constructor(private mailer: Mailer) {}
  sendWelcomeEmail(userId: string): void { /* ... */ }
  sendInvoice(userId: string, invoiceId: string): void { /* ... */ }
}

class BillingService {
  constructor(private stripe: StripeClient) {}
  createSubscription(userId: string, plan: string): Subscription { /* ... */ }
  processRefund(userId: string, amount: number): void { /* ... */ }
}
```

### Step 4 — Design Pattern (`design-patterns-creational-structural`)

**Facade** — single entry point for callers needing coordinated operations across services.

```typescript
class UserFacade {
  constructor(
    private auth: AuthService,
    private profile: ProfileService,
    private notifications: NotificationService,
    private billing: BillingService,
  ) {}

  async registerUser(email: string, password: string, plan: string): Promise<User> {
    const session = await this.auth.login(email, password);
    const user = await this.profile.updateProfile(session.userId, { email });
    await this.billing.createSubscription(session.userId, plan);
    await this.notifications.sendWelcomeEmail(session.userId);
    return user;
  }
}
```

**Result:** Each service is independently testable. The Facade composes them for multi-step flows without re-coupling the caller to every service.

---

## Walkthrough 2: Switch Statement → Strategy Pattern

### Step 1 — Smell Detection (`detect-code-smells`)

Switch Statements smell: method branches on a type code to select calculation logic.

```typescript
// BEFORE: switch on shipping method
function calculateShipping(order: Order): number {
  switch (order.shippingMethod) {
    case 'standard': return order.weight * 0.5 + 2.99;
    case 'express':  return order.weight * 1.2 + 9.99;
    case 'overnight': return order.weight * 2.5 + 24.99;
    case 'free': return 0;
    default: throw new Error(`Unknown method: ${order.shippingMethod}`);
  }
}
```

Each new shipping method requires editing this function and every similar switch elsewhere.

### Step 2 — Anti-Pattern Check (`anti-patterns-catalog`)

**Switch on Type Code** — the switch will replicate into discount calculation, label printing, and carrier selection as the feature grows.

### Step 3 — Refactoring (`refactor-simplifying-conditionals`)

Replace Conditional with Polymorphism — push each branch into its own class behind a shared interface.

```typescript
// AFTER: one interface, one class per variant
interface ShippingStrategy { calculate(order: Order): number; }

class StandardShipping implements ShippingStrategy {
  calculate(order: Order): number { return order.weight * 0.5 + 2.99; }
}
class ExpressShipping implements ShippingStrategy {
  calculate(order: Order): number { return order.weight * 1.2 + 9.99; }
}
class OvernightShipping implements ShippingStrategy {
  calculate(order: Order): number { return order.weight * 2.5 + 24.99; }
}
class FreeShipping implements ShippingStrategy {
  calculate(_order: Order): number { return 0; }
}
```

### Step 4 — Design Pattern (`design-patterns-behavioral`)

**Strategy** — context delegates to the selected strategy; new methods extend without touching existing code.

```typescript
class ShippingCalculator {
  private strategies: Record<string, ShippingStrategy> = {
    standard: new StandardShipping(),
    express: new ExpressShipping(),
    overnight: new OvernightShipping(),
    free: new FreeShipping(),
  };

  calculate(order: Order): number {
    const s = this.strategies[order.shippingMethod];
    if (!s) throw new Error(`Unknown method: ${order.shippingMethod}`);
    return s.calculate(order);
  }
}
```

**Result:** Adding a new shipping type is one new class. Each strategy tests in isolation. The calculator itself never changes.

---

## Walkthrough 3: Callback Hell → Function Composition + Observer

### Step 1 — Smell Detection (`detect-code-smells`)

Long Method + deep nesting: callbacks nest 4 levels, error handling duplicated at each layer.

```typescript
// BEFORE: pyramid of callbacks
function processOrder(orderId: string, cb: (err: Error | null, result?: Receipt) => void) {
  db.findOrder(orderId, (err, order) => {
    if (err) { cb(err); return; }
    payment.charge(order.total, order.customerId, (err, charge) => {
      if (err) { cb(err); return; }
      inventory.reserve(order.items, (err, reservation) => {
        if (err) { cb(err); return; }
        mailer.confirm(order.customerId, (err) => {
          if (err) { cb(err); return; }
          cb(null, { orderId, chargeId: charge.id, reservationId: reservation.id });
        });
      });
    });
  });
}
```

### Step 2 — Anti-Pattern Check (`anti-patterns-catalog`)

**Spaghetti Code** — adding a fraud-check step means nesting deeper and duplicating `if (err)` again.

### Step 3 — Refactoring (`refactor-functional-patterns`)

Extract Method + async composition — lift each step into a named async function; let `try/catch` at the call site handle all errors.

```typescript
// AFTER: flat async pipeline
async function findOrder(id: string): Promise<Order> { return db.findOrder(id); }

async function chargeCustomer(order: Order): Promise<ChargedOrder> {
  const charge = await payment.charge(order.total, order.customerId);
  return { ...order, chargeId: charge.id };
}

async function reserveInventory(order: ChargedOrder): Promise<FulfilledOrder> {
  const reservation = await inventory.reserve(order.items);
  return { ...order, reservationId: reservation.id };
}

async function processOrder(orderId: string): Promise<Receipt> {
  const fulfilled = await reserveInventory(await chargeCustomer(await findOrder(orderId)));
  bus.emit('order.fulfilled', fulfilled);
  return { orderId, chargeId: fulfilled.chargeId, reservationId: fulfilled.reservationId };
}
```

### Step 4 — Design Pattern (`design-patterns-behavioral`)

**Observer** — post-fulfillment side effects (email, analytics) attach to an event bus; `processOrder` does not know about them.

```typescript
const bus = new EventEmitter();
bus.on('order.fulfilled', ({ customerId }) => mailer.sendConfirmation(customerId));
bus.on('order.fulfilled', ({ orderId }) => analytics.track('order_completed', orderId));
```

**Result:** Each pipeline step is independently testable. Adding a new side effect is one `bus.on` call — `processOrder` is never modified.

---

## Walkthrough 4: Primitive Obsession → Value Objects + Builder

### Step 1 — Smell Detection (`detect-code-smells`)

Primitive Obsession + Long Parameter List: six raw strings for an address with no validation.

```typescript
// BEFORE: six positional strings — easy to swap city and state by mistake
function createShipment(
  recipientName: string, streetLine1: string, streetLine2: string,
  city: string, state: string, postalCode: string,
): Shipment {
  return { label: `${recipientName}\n${streetLine1}\n${city}, ${state} ${postalCode}`, carrier: selectCarrier(state) };
}
```

### Step 2 — Anti-Pattern Check (`anti-patterns-catalog`)

**Primitive Obsession** — validation, formatting, and equality checks for address data duplicate across every caller.

### Step 3 — Refactoring (`refactor-organizing-data`, `refactor-simplifying-method-calls`)

Replace Data Value with Object + Introduce Parameter Object — encapsulate the address fields with built-in validation.

```typescript
// AFTER: Address value object validates on construction
class Address {
  constructor(
    readonly recipientName: string, readonly streetLine1: string, readonly streetLine2: string,
    readonly city: string, readonly state: string, readonly postalCode: string,
  ) {
    if (!recipientName.trim()) throw new Error('recipientName required');
    if (!/^[A-Z]{2}$/.test(state)) throw new Error('state must be 2-letter code');
    if (!/^\d{5}(-\d{4})?$/.test(postalCode)) throw new Error('invalid postalCode');
  }

  format(): string {
    const lines = [this.recipientName, this.streetLine1];
    if (this.streetLine2) lines.push(this.streetLine2);
    return [...lines, `${this.city}, ${this.state} ${this.postalCode}`].join('\n');
  }
}

function createShipment(address: Address): Shipment {
  return { label: address.format(), carrier: selectCarrier(address.state) };
}
```

### Step 4 — Design Pattern (`design-patterns-creational-structural`)

**Builder** — fluent API for optional fields; validation fires only when `build()` is called.

```typescript
class AddressBuilder {
  private p: Partial<ConstructorParameters<typeof Address>> = [];

  recipient(name: string): this { this.p[0] = name; return this; }
  street(line1: string, line2 = ''): this { this.p[1] = line1; this.p[2] = line2; return this; }
  location(city: string, state: string, zip: string): this { this.p[3] = city; this.p[4] = state; this.p[5] = zip; return this; }
  build(): Address { return new Address(...(this.p as ConstructorParameters<typeof Address>)); }
}

// Self-documenting call site — no positional confusion
const shipment = createShipment(
  new AddressBuilder().recipient('Jane Smith').street('123 Main St', 'Apt 4B').location('Springfield', 'IL', '62701').build()
);
```

**Result:** Validation is centralised in `Address`. Positional swap bugs are eliminated. New fields require one new builder method.

---

## Quick Reference

| Smell | Anti-Pattern | Refactoring | Pattern |
|-------|-------------|-------------|---------|
| Large Class (15+ methods, mixed concerns) | God Object | Extract Class (`refactor-moving-features`) | Facade (`design-patterns-creational-structural`) |
| Switch Statements on type code | Switch on Type Code | Replace Conditional with Polymorphism (`refactor-simplifying-conditionals`) | Strategy (`design-patterns-behavioral`) |
| Long Method + deep nesting | Spaghetti Code | Extract Method + async compose (`refactor-functional-patterns`) | Observer (`design-patterns-behavioral`) |
| Primitive Obsession + Long Parameter List | Primitive Obsession | Replace Data Value with Object + Introduce Parameter Object | Builder (`design-patterns-creational-structural`) |

---

## Cross-References

| Topic | Skill |
|-------|-------|
| Detecting bloater and change preventer smells | `detect-code-smells` |
| God Object, Spaghetti Code, Primitive Obsession definitions | `anti-patterns-catalog` |
| Extract Class, Move Method | `refactor-moving-features` |
| Replace Conditional with Polymorphism | `refactor-simplifying-conditionals` |
| Extract Method, function composition | `refactor-functional-patterns` |
| Replace Data Value with Object, Encapsulate Field | `refactor-organizing-data` |
| Introduce Parameter Object | `refactor-simplifying-method-calls` |
| Strategy, Observer patterns | `design-patterns-behavioral` |
| Facade, Builder patterns | `design-patterns-creational-structural` |
