---
name: dependency-injection-module-patterns
description: Use when reviewing code for dependency coupling problems or module organisation issues — covers 6 DI patterns (Constructor, Property, Method, Interface, Service Locator, DI Container), Composition Root, Module/Package organisation, and a catalogue of DI anti-patterns with multi-language examples
---

# Dependency Injection and Module Patterns

## Overview

Dependency Injection (DI) supplies an object's dependencies from outside rather than letting it create them. Combined with the Dependency Inversion Principle (DIP), it is the primary technique for loose coupling. Module/package organisation either enables or defeats DI by controlling dependency direction.

**Cross-reference:** DIP — `review-solid-clean-code`; Factory patterns in Composition Root — `design-patterns-creational-structural`

## When to Use

- Business logic creates its own collaborators (`new ConcreteClass()` inside services)
- Hidden dependencies make unit testing impossible without real infrastructure
- Evaluating framework wiring (Spring, tsyringe, FastAPI, Wire) for correctness and scope
- Reviewing module boundaries for circular imports or over-coupled packages

## Quick Reference

| Pattern | Core Problem Solved | Key Red Flag |
|---------|---------------------|--------------|
| Constructor Injection | Mandatory deps declared up front | `new ConcreteClass()` inside business logic |
| Property Injection | Optional or framework-set deps | Always-required dep set via property |
| Method Injection | Per-call dependency variation | Method signature grows with each new dep |
| Interface Injection | Dependency via injector interface | Overcomplicates simple injection needs |
| Service Locator | Centralised dependency registry | `Locator.get()` scattered through business logic |
| DI Container / IoC | Framework manages full dep graph | `container.resolve()` deep in business logic |
| Composition Root | Single assembly point for object graph | Wiring logic leaking into domain layer |
| Module Organisation | Package boundaries enforce coupling | Circular imports, barrel file blowout |

---

## DI Patterns

### 1. Constructor Injection

All required dependencies as constructor parameters. The default and preferred form.

**Use when** dependency is mandatory. **Skip when** circular deps make construction impossible (fix the design) or framework requires no-arg constructor.

```typescript
interface OrderRepository { findById(id: string): Promise<Order>; }
interface PaymentGateway   { charge(order: Order): Promise<Receipt>; }

class OrderService {
  constructor(
    private readonly repo: OrderRepository,
    private readonly gateway: PaymentGateway,
  ) {}

  async process(id: string): Promise<Receipt> {
    const order = await this.repo.findById(id);
    return this.gateway.charge(order);
  }
}
```

```java
// Spring — constructor injection (preferred over @Autowired field)
@Service
public class OrderService {
    private final OrderRepository repo;
    private final PaymentGateway gateway;

    public OrderService(OrderRepository repo, PaymentGateway gateway) {
        this.repo    = repo;
        this.gateway = gateway;
    }
}
```

```python
class OrderService:
    def __init__(self, repo: OrderRepository, gateway: PaymentGateway) -> None:
        self._repo    = repo
        self._gateway = gateway
```

```go
type OrderService struct {
    repo    OrderRepository
    gateway PaymentGateway
}

func NewOrderService(repo OrderRepository, gateway PaymentGateway) *OrderService {
    return &OrderService{repo: repo, gateway: gateway}
}
```

**Red Flags:** `new ConcreteClass()` in service method; constructor with 7+ params (SRP violation); parameter typed as concrete class instead of interface.

---

### 2. Property / Setter Injection

Dependencies set via properties after construction. For optional dependencies or framework lifecycle requirements.

**Use when** dependency is genuinely optional with a null-object default. **Skip when** dependency is actually required (temporal coupling: object invalid between construction and setter call).

```typescript
class ReportGenerator {
  logger: Logger = new NullLogger(); // safe default
  generate(data: Dataset): Report { /* ... */ }
}
```

```java
@Service
public class ReportGenerator {
    private Logger logger = new NullLogger();

    @Autowired(required = false)
    public void setLogger(Logger logger) { this.logger = logger; }
}
```

**Red Flags:** "optional" dep accessed on every code path (it's required — move to constructor); mutable public field; object used before setters called.

---

### 3. Method Injection

Dependency passed as parameter to the method that uses it.

**Use when** dependency varies per call (execution context, per-request logger, transaction handle). **Skip when** same dep used by many methods (store in constructor) or parameter list grows unbounded.

```typescript
class AuditService {
  record(event: AuditEvent, logger: Logger): void {
    logger.info(`Audit: ${event.type} by ${event.userId}`);
  }
}
```

```go
func (s *AuditService) Record(ctx context.Context, event AuditEvent) error {
    log := loggerFromCtx(ctx)  // canonical Go method injection
    log.Info("audit", "type", event.Type)
    return nil
}
```

**Red Flags:** signature keeps growing with new dep params; same dep passed to every method (move to constructor); method receives both work data and dep factory.

---

### 4. Interface Injection

Dependency provides an injector interface; dependent class implements it to receive the dependency. Used by plugin frameworks (e.g., Spring's `*Aware` interfaces).

**Skip when** Constructor Injection can express the same intent — it almost always can.

```typescript
interface LoggerAware { setLogger(logger: Logger): void; }
class DataImporter implements LoggerAware {
  private logger: Logger = new NullLogger();
  setLogger(logger: Logger): void { this.logger = logger; }
}
```

**Red Flags:** used for a required dep (use Constructor Injection); hand-rolled `setLogger` calls scattered through codebase without framework driving it.

---

### 5. Service Locator (Anti-Pattern)

Centralised registry returns dependencies on demand. Dependencies are hidden — constructor signature doesn't reveal needs. Testing requires configuring global registry.

**Acceptable:** legacy codebases where constructor injection can't be introduced everywhere; plugin registries with open-ended, compile-time-unknown sets.

```typescript
// BAD — hidden dependency
class OrderService {
  process(id: string): Receipt {
    const repo = ServiceLocator.get<OrderRepository>('OrderRepository');
    // ...
  }
}

// GOOD — inject at construction
class OrderService {
  constructor(private repo: OrderRepository, private gateway: PaymentGateway) {}
}
```

**Red Flags:** `ServiceLocator.get()` / `container.resolve()` in domain logic; tests pre-configure global registry; can't determine deps without reading full implementation.

---

### 6. DI Container / IoC Container

Framework reads the dependency graph (annotations, config, convention) and constructs all objects with correct dependencies.

**Common frameworks:** Java — Spring; TypeScript — tsyringe, InversifyJS; Python — FastAPI `Depends`; Go — `wire`.

```typescript
// tsyringe — Composition Root
@injectable()
class OrderService {
  constructor(
    @inject('OrderRepository') private repo: OrderRepository,
    @inject('PaymentGateway')  private gateway: PaymentGateway,
  ) {}
}
container.register('OrderRepository', { useClass: SqlOrderRepository });
container.register('PaymentGateway',  { useClass: StripeGateway });
const svc = container.resolve(OrderService); // only at entry point
```

**Red Flags:** `container.resolve()` in business/domain logic; circular dep at startup (design flaw); singleton-scoped service holds request-scoped dep (Captive Dependency); framework magic obscures actual dep graph.

---

### 7. Composition Root

Single location (typically entry point) where the entire dependency graph is assembled.

```typescript
// Manual Composition Root — index.ts
const db      = new PostgresConnection(process.env.DATABASE_URL!);
const repo    = new SqlOrderRepository(db);
const gateway = new StripeGateway(process.env.STRIPE_KEY!);
const service = new OrderService(repo, gateway);
const handler = new OrderHandler(service);
app.post('/orders/:id/process', handler.process.bind(handler));
```

**Red Flags:** `new ConcreteService(new ConcreteRepo(new Db()))` buried in domain class; multiple Composition Roots (inconsistent wiring); container config spread across many modules.

---

### 8. Module / Package Organisation

Group code so high-level modules don't depend on low-level modules. Interfaces in high-level layer; implementations in low-level layer.

```
src/
  domain/          # pure business logic; no framework imports
    OrderRepository.ts  # interface only
  application/     # depends on domain interfaces only
    OrderService.ts
  infrastructure/  # implements domain interfaces; imports external libs
    SqlOrderRepository.ts
    StripeGateway.ts
  composition/     # wires all layers; only place importing everything
    container.ts
```

**Red Flags:** `domain/` imports from `infrastructure/`; circular imports (`A → B → A`); barrel files re-exporting every symbol; packages named by technical role (`utils/`) instead of domain concept.

---

## DI Anti-Patterns

### Bastard Injection
Constructor silently creates concrete defaults — hides dependencies, untestable by default.
```typescript
// BAD: private repo = new SqlOrderRepository();
// GOOD: constructor(private repo: OrderRepository) {}
```

### Captive Dependency
Longer-lived object captures shorter-lived dependency. Example: `@Singleton` injected with `@RequestScoped` bean — only one request's instance ever used. **Fix:** inject `Provider<T>` or `@Lookup`.

### Ambient Context
Static/thread-local infrastructure access (`DateTime.Now`, `HttpContext.Current`) bypasses DI. **Fix:** inject abstractions — `IClock`, `IHttpContextAccessor`.

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `new ConcreteClass()` in business logic | Move to Composition Root; inject the interface |
| Constructor with 7+ parameters | Split the class — too many responsibilities |
| `@Autowired` on a field (Java/Spring) | Constructor injection; field injection hides deps, prevents `final` |
| Service Locator in domain code | Refactor to Constructor Injection |
| Singleton holding request-scoped dep | Inject `Provider<T>`; let container manage scope |
| Circular imports between packages | Extract shared interface package |
| Barrel re-exports of all symbols | Export only public API |

---

## Decision Flowchart

```
Is the dependency required for the object to function?
  YES → Constructor Injection (default choice)
  NO  → Property Injection with null-object default

Does the dependency vary per method call?
  YES → Method Injection (pass as parameter)
  NO  → Constructor Injection

Is the set of implementations open-ended / plugin-based?
  YES → Service Locator acceptable at the plugin boundary only
  NO  → Never use Service Locator in domain logic

Is object graph large with cross-cutting concerns (e.g., request scoping)?
  YES → DI Container; assemble at Composition Root; check scopes
  NO  → Manual wiring at Composition Root is simpler
```

## Cross-References

| Topic | Skill |
|-------|-------|
| Dependency Inversion Principle (SOLID 'D') | `review-solid-clean-code` |
| Factory Method / Abstract Factory in Composition Root | `design-patterns-creational-structural` |
| Singleton and when DI replaces it | `design-patterns-creational-structural` |
| God Class / Feature Envy from hidden deps | `detect-code-smells` |
