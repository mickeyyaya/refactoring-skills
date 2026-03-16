---
name: pattern-detection-walkthroughs
description: Use when you need end-to-end examples of detecting a code smell, identifying the underlying anti-pattern, selecting a refactoring technique, and applying the appropriate design pattern — each walkthrough traces the full diagnostic flow with before/after TypeScript code
---

# Pattern Detection Walkthroughs

## Diagnostic Flow

Each walkthrough follows four steps:
1. **Smell Detection** (`detect-code-smells`)
2. **Anti-Pattern Check** (`anti-patterns-catalog`)
3. **Refactoring Selection** (refactor skills)
4. **Design Pattern** (prevent recurrence)

---

## Walkthrough 1: God Class → Extract Class + Facade

**Smell:** Large Class — 15+ methods across auth, profiles, email, billing.

```typescript
// BEFORE: UserManager does everything
class UserManager {
  private db: Database; private mailer: Mailer; private stripe: StripeClient;
  login(email: string, password: string): Session { /* ... */ }
  logout(sessionId: string): void { /* ... */ }
  updateProfile(userId: string, data: ProfileData): User { /* ... */ }
  sendWelcomeEmail(userId: string): void { /* ... */ }
  createSubscription(userId: string, plan: string): Subscription { /* ... */ }
  processRefund(userId: string, amount: number): void { /* ... */ }
  // ... 8 more methods
}
```

**Anti-Pattern:** God Object — changes to billing break auth; every dev edits same file.

**Refactoring:** Extract Class per responsibility (`refactor-moving-features`).

```typescript
// AFTER: focused services
class AuthService { login(...) { } logout(...) { } }
class ProfileService { updateProfile(...) { } deleteAccount(...) { } }
class NotificationService { sendWelcomeEmail(...) { } sendInvoice(...) { } }
class BillingService { createSubscription(...) { } processRefund(...) { } }
```

**Pattern:** Facade — single entry point for coordinated multi-service flows.

```typescript
class UserFacade {
  constructor(private auth: AuthService, private profile: ProfileService,
    private notifications: NotificationService, private billing: BillingService) {}

  async registerUser(email: string, password: string, plan: string): Promise<User> {
    const session = await this.auth.login(email, password);
    await this.billing.createSubscription(session.userId, plan);
    await this.notifications.sendWelcomeEmail(session.userId);
    return this.profile.updateProfile(session.userId, { email });
  }
}
```

---

## Walkthrough 2: Switch Statement → Strategy Pattern

**Smell:** Switch on type code for shipping calculation.

```typescript
// BEFORE
function calculateShipping(order: Order): number {
  switch (order.shippingMethod) {
    case 'standard': return order.weight * 0.5 + 2.99;
    case 'express':  return order.weight * 1.2 + 9.99;
    case 'overnight': return order.weight * 2.5 + 24.99;
    case 'free': return 0;
    default: throw new Error(`Unknown: ${order.shippingMethod}`);
  }
}
```

**Anti-Pattern:** Switch on Type Code — replicates into discount, label printing, carrier selection.

**Refactoring:** Replace Conditional with Polymorphism (`refactor-simplifying-conditionals`).

```typescript
interface ShippingStrategy { calculate(order: Order): number; }
class StandardShipping implements ShippingStrategy { calculate(order: Order) { return order.weight * 0.5 + 2.99; } }
class ExpressShipping implements ShippingStrategy { calculate(order: Order) { return order.weight * 1.2 + 9.99; } }
class OvernightShipping implements ShippingStrategy { calculate(order: Order) { return order.weight * 2.5 + 24.99; } }
class FreeShipping implements ShippingStrategy { calculate(_order: Order) { return 0; } }
```

**Pattern:** Strategy — new shipping type = one new class. Calculator never changes.

```typescript
class ShippingCalculator {
  private strategies: Record<string, ShippingStrategy> = {
    standard: new StandardShipping(), express: new ExpressShipping(),
    overnight: new OvernightShipping(), free: new FreeShipping(),
  };
  calculate(order: Order): number {
    const s = this.strategies[order.shippingMethod];
    if (!s) throw new Error(`Unknown: ${order.shippingMethod}`);
    return s.calculate(order);
  }
}
```

---

## Walkthrough 3: Callback Hell → Function Composition + Observer

**Smell:** Long Method + 4-level nesting with duplicated error handling.

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

**Anti-Pattern:** Spaghetti Code — adding a step means nesting deeper.

**Refactoring:** Extract Method + async composition (`refactor-functional-patterns`).

```typescript
// AFTER: flat async pipeline
async function processOrder(orderId: string): Promise<Receipt> {
  const order = await db.findOrder(orderId);
  const charge = await payment.charge(order.total, order.customerId);
  const reservation = await inventory.reserve(order.items);
  bus.emit('order.fulfilled', { orderId, customerId: order.customerId });
  return { orderId, chargeId: charge.id, reservationId: reservation.id };
}
```

**Pattern:** Observer — side effects attach to event bus; `processOrder` never modified for new effects.

```typescript
bus.on('order.fulfilled', ({ customerId }) => mailer.sendConfirmation(customerId));
bus.on('order.fulfilled', ({ orderId }) => analytics.track('order_completed', orderId));
```

---

## Walkthrough 4: Primitive Obsession → Value Objects + Builder

**Smell:** Six raw strings for an address with no validation.

```typescript
// BEFORE: positional strings — easy to swap city/state
function createShipment(recipientName: string, streetLine1: string, streetLine2: string,
  city: string, state: string, postalCode: string): Shipment { /* ... */ }
```

**Anti-Pattern:** Primitive Obsession — validation/formatting duplicated across callers.

**Refactoring:** Replace Data Value with Object + Introduce Parameter Object.

```typescript
class Address {
  constructor(readonly recipientName: string, readonly streetLine1: string,
    readonly streetLine2: string, readonly city: string,
    readonly state: string, readonly postalCode: string) {
    if (!recipientName.trim()) throw new Error('recipientName required');
    if (!/^[A-Z]{2}$/.test(state)) throw new Error('state must be 2-letter code');
    if (!/^\d{5}(-\d{4})?$/.test(postalCode)) throw new Error('invalid postalCode');
  }
  format(): string { /* ... */ }
}
function createShipment(address: Address): Shipment { /* ... */ }
```

**Pattern:** Builder — fluent API; validation fires on `build()`.

```typescript
const shipment = createShipment(
  new AddressBuilder().recipient('Jane Smith').street('123 Main St', 'Apt 4B')
    .location('Springfield', 'IL', '62701').build()
);
```

---

## Quick Reference

| Smell | Anti-Pattern | Refactoring | Pattern |
|-------|-------------|-------------|---------|
| Large Class (15+ methods) | God Object | Extract Class | Facade |
| Switch on type code | Switch on Type Code | Replace Conditional with Polymorphism | Strategy |
| Long Method + deep nesting | Spaghetti Code | Extract Method + async compose | Observer |
| Primitive Obsession + Long Param List | Primitive Obsession | Value Object + Parameter Object | Builder |

---

## Cross-References

| Topic | Skill |
|-------|-------|
| Smell detection | `detect-code-smells` |
| Anti-pattern definitions | `anti-patterns-catalog` |
| Extract Class, Move Method | `refactor-moving-features` |
| Replace Conditional with Polymorphism | `refactor-simplifying-conditionals` |
| Function composition | `refactor-functional-patterns` |
| Value Object, Encapsulate Field | `refactor-organizing-data` |
| Introduce Parameter Object | `refactor-simplifying-method-calls` |
| Strategy, Observer | `design-patterns-behavioral` |
| Facade, Builder | `design-patterns-creational-structural` |
