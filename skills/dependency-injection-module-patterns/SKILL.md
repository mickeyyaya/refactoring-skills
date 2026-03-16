---
name: dependency-injection-module-patterns
description: Use when reviewing code for dependency coupling problems or module organisation issues — covers 6 DI patterns (Constructor, Property, Method, Interface, Service Locator, DI Container), Composition Root, Module/Package organisation, and a catalogue of DI anti-patterns with multi-language examples
---

# Dependency Injection and Module Patterns

## Overview

Dependency Injection (DI) is the practice of supplying an object's dependencies from the outside rather than letting the object create them. Combined with the Dependency Inversion Principle (DIP), it is the primary technique for achieving loose coupling in object-oriented and functional codebases. Module/package organisation decisions either enable or defeat DI by controlling what can depend on what.

**Cross-reference:** DIP (the 'D' in SOLID) — `review-solid-clean-code`; Factory patterns used in Composition Root — `design-patterns-creational-structural`

## When to Use

- Reviewing code where business logic creates its own collaborators (`new ConcreteClass()` inside services)
- Identifying hidden dependencies that make unit testing impossible without real infrastructure
- Evaluating framework wiring (Spring, tsyringe, FastAPI, Wire) for correctness and scope issues
- Reviewing module/package boundaries for circular imports or over-coupled packages

## Quick Reference

| Pattern | Category | Core Problem Solved | Key Red Flag |
|---------|----------|---------------------|--------------|
| Constructor Injection | DI | Mandatory dependencies declared up front | `new ConcreteClass()` inside business logic |
| Property Injection | DI | Optional or framework-set dependencies | Always-required dependency set via property |
| Method Injection | DI | Per-call dependency variation | Method signature changes every time a new dep added |
| Interface Injection | DI | Dependency provided through injector interface | Overcomplicates simple injection needs |
| Service Locator | Anti-pattern | Centralised dependency registry | `Locator.get()` scattered through business logic |
| DI Container / IoC | Infrastructure | Framework manages full dependency graph | `container.resolve()` deep in business logic |
| Composition Root | Structural | Single assembly point for object graph | Wiring logic leaking into domain layer |
| Module Organisation | Structural | Package boundaries enforce coupling rules | Circular imports, barrel file blowout |

---

## DI Patterns

### 1. Constructor Injection

**Intent:** All required dependencies are declared as constructor parameters. The object is fully initialized and ready to use after construction.

**When to Use:** Whenever a dependency is mandatory for the object to function. This is the default and preferred form of DI in almost every language and framework.

**When NOT to Use:** Circular dependency graph makes construction impossible (fix the design, do not switch to setter injection as a workaround). Frameworks that require a no-arg constructor may force alternatives.

```typescript
// TypeScript — manual wiring
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
// Java / Spring — framework constructor injection (preferred over @Autowired field)
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
# Python — manual wiring; inject library optional
class OrderService:
    def __init__(self, repo: OrderRepository, gateway: PaymentGateway) -> None:
        self._repo    = repo
        self._gateway = gateway
```

```go
// Go — interfaces wired at Composition Root
type OrderService struct {
    repo    OrderRepository
    gateway PaymentGateway
}

func NewOrderService(repo OrderRepository, gateway PaymentGateway) *OrderService {
    return &OrderService{repo: repo, gateway: gateway}
}
```

**Code Review Red Flags**
- `new ConcreteClass()` inside a service method — concrete creation belongs in the Composition Root
- Constructor with 7+ parameters — split the class (Single Responsibility violation)
- Parameter typed as a concrete class instead of an interface — breaks substitutability

---

### 2. Property / Setter Injection

**Intent:** Dependencies are set via public properties or setter methods after construction. Appropriate for optional dependencies or framework lifecycle requirements.

**When to Use:** Dependency is genuinely optional (object functions without it, using a null-object default). Framework requires a no-arg constructor and sets dependencies via reflection.

**When NOT to Use:** Dependency is actually required — use Constructor Injection. Leads to temporal coupling: the object is in an invalid state between construction and the first setter call.

```typescript
class ReportGenerator {
  logger: Logger = new NullLogger(); // safe default, not a required dep

  generate(data: Dataset): Report { /* ... */ }
}
// Caller may optionally inject: gen.logger = new ConsoleLogger();
```

```java
@Service
public class ReportGenerator {
    private Logger logger = new NullLogger(); // optional

    @Autowired(required = false)
    public void setLogger(Logger logger) { this.logger = logger; }
}
```

**Code Review Red Flags**
- "Optional" dependency that is accessed on every code path — it is required; move it to the constructor
- Mutable public field for a dependency — any caller can replace it mid-execution
- Object used before all setters have been called — missing lifecycle guard

---

### 3. Method Injection

**Intent:** A dependency is passed as a parameter to the specific method that uses it, rather than stored on the object.

**When to Use:** Dependency varies per call (e.g., the current user's execution context, a per-request logger, a transaction handle).

**When NOT to Use:** The same dependency is used by many methods — store it in the constructor. The method parameter list grows unbounded as new dependencies are discovered.

```typescript
class AuditService {
  record(event: AuditEvent, logger: Logger): void {
    logger.info(`Audit: ${event.type} by ${event.userId}`);
  }
}
```

```go
func (s *AuditService) Record(ctx context.Context, event AuditEvent) error {
    // ctx carries per-request logger, tracer, deadline — canonical Go method injection
    log := loggerFromCtx(ctx)
    log.Info("audit", "type", event.Type)
    return nil
}
```

**Code Review Red Flags**
- Method signature keeps growing with new dependency parameters across releases
- Same dependency passed to every method of the class — move it to the constructor
- Method receives both the work data and the dependency factory — too many responsibilities

---

### 4. Interface Injection

**Intent:** The dependency provides an injector interface; the dependent class implements it to receive the dependency. Used by some plugin frameworks (e.g., Spring's `*Aware` interfaces).

**When NOT to Use:** Whenever Constructor Injection can express the same intent — it almost always can. The extra interface adds indirection with no benefit in application code.

```typescript
interface LoggerAware { setLogger(logger: Logger): void; }
class DataImporter implements LoggerAware {
  private logger: Logger = new NullLogger();
  setLogger(logger: Logger): void { this.logger = logger; }
}
```

**Code Review Red Flags**
- Used for a required dependency — use Constructor Injection instead
- Framework is not driving injection — hand-rolled `setLogger` calls scattered through the codebase

---

### 5. Service Locator (Anti-Pattern)

**Intent:** A centralised registry returns the dependency on demand. The object pulls its dependencies at runtime.

**Why It Is an Anti-Pattern:** Dependencies are hidden — you cannot tell from the constructor signature what a class needs. Testing requires configuring the global registry before each test. Changes to the registry affect all consumers silently.

**When Acceptable:** Legacy codebases where constructor injection cannot be introduced everywhere yet; plugin/extension registries where the set of plugins is open-ended and unknown at compile time.

```typescript
// BAD — hidden dependency on ServiceLocator
class OrderService {
  process(id: string): Receipt {
    const repo    = ServiceLocator.get<OrderRepository>('OrderRepository');
    const gateway = ServiceLocator.get<PaymentGateway>('PaymentGateway');
    // ... business logic
  }
}

// GOOD — inject at construction, expose in signature
class OrderService {
  constructor(private repo: OrderRepository, private gateway: PaymentGateway) {}
}
```

**Code Review Red Flags**
- `ServiceLocator.get()` / `container.resolve()` called inside domain or application logic
- Tests that pre-configure a global registry before each test case
- No way to determine a class's dependencies without reading its full implementation

---

### 6. DI Container / IoC Container

**Intent:** A framework reads the dependency graph (via annotations, configuration, or convention) and constructs all objects with their correct dependencies.

**Common frameworks:** Java — Spring (`@Bean`, `@Component`); TypeScript — tsyringe (`@injectable`), InversifyJS; Python — `inject`, FastAPI `Depends`; Go — `wire` (compile-time codegen).

```typescript
// TypeScript / tsyringe — Composition Root
import { injectable, inject, container } from 'tsyringe';

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

```java
// Spring Boot — framework drives wiring; no container.resolve() in business code
@SpringBootApplication
public class App { public static void main(String[] a) { SpringApplication.run(App.class, a); } }
```

**Code Review Red Flags**
- `container.resolve()` called inside business or domain logic — belongs only in Composition Root or entry points
- Circular dependency detected at startup — design flaw, not a container configuration issue
- Singleton-scoped service holds a reference to a request-scoped dependency (see Captive Dependency anti-pattern)
- Over-reliance on framework magic obscures the actual dependency graph

---

### 7. Composition Root

**Intent:** A single location in the application (typically the entry point) where the entire dependency graph is assembled. All `new` calls for long-lived objects happen here.

**When to Use:** Every application that uses DI should have one, whether using a container or manual wiring.

```typescript
// Manual Composition Root — index.ts / main.ts
const db      = new PostgresConnection(process.env.DATABASE_URL!);
const repo    = new SqlOrderRepository(db);
const gateway = new StripeGateway(process.env.STRIPE_KEY!);
const service = new OrderService(repo, gateway);
const handler = new OrderHandler(service);
app.post('/orders/:id/process', handler.process.bind(handler));
```

**Code Review Red Flags**
- `new ConcreteService(new ConcreteRepository(new DbConnection()))` buried deep inside a domain class
- Multiple Composition Roots in one app — inconsistent wiring, risk of double-instantiation
- Container configuration spread across many modules — hard to reason about lifetime and scope

---

### 8. Module / Package Organisation

**Intent:** Group code so that high-level modules do not depend on low-level modules. Interfaces live in the high-level layer; implementations live in the low-level layer.

```
src/
  domain/          # pure business logic; no framework imports
    OrderRepository.ts  # interface only
  application/     # depends on domain interfaces only
    OrderService.ts
  infrastructure/  # implements domain interfaces; imports external libs
    SqlOrderRepository.ts
    StripeGateway.ts
  composition/     # wires all layers; only place that imports everything
    container.ts
```

**Code Review Red Flags**
- `domain/` imports from `infrastructure/` — inverted dependency direction
- Circular imports between packages (`A → B → A`) — extract a shared abstraction
- Barrel files (`index.ts`) re-exporting every symbol — forces transitive dependencies on all importers
- Package named by technical role (`utils/`, `helpers/`) instead of domain concept

---

## DI Anti-Patterns

### Bastard Injection

Constructor silently creates concrete dependencies as defaults — hides dependencies, makes the easy path untestable.

```typescript
// BAD: private repo = new SqlOrderRepository();
// GOOD: constructor(private repo: OrderRepository) {}
```

### Captive Dependency

A longer-lived object captures a shorter-lived dependency. Example: Spring `@Singleton` bean injected with a `@RequestScoped` bean at construction — only one request's instance is ever used. **Fix:** inject `Provider<T>` or use `@Lookup` so the container creates a fresh instance per call.

### Service Locator as Default

Defaulting to `ServiceLocator.get()` when Constructor Injection is readily available — symptom of DI not being established as the team norm.

### Ambient Context

Static/thread-local access to infrastructure (`DateTime.Now`, `HttpContext.Current`, `SecurityContextHolder.getContext()`) bypasses DI and makes logic untestable. **Fix:** inject an abstraction — `IClock`, `IHttpContextAccessor`, `ISecurityContext`.

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `new ConcreteClass()` in business logic | Move to Composition Root; inject the interface |
| Constructor with 7+ parameters | Split the class — it has too many responsibilities |
| `@Autowired` on a field (Java/Spring) | Use constructor injection; field injection hides deps and prevents `final` |
| Service Locator scattered through domain code | Refactor to Constructor Injection; Service Locator belongs only at entry points |
| Singleton holding a request-scoped dependency | Inject `Provider<T>`; let the container manage scope |
| Circular imports between packages | Extract a shared interface package; restructure so dep direction is consistent |
| Barrel re-exports of all symbols | Export only public API; keep internal implementations unexported |

---

## Decision Flowchart

```
Is the dependency required for the object to function?
  YES → Constructor Injection (default choice)
  NO  → Property Injection with a safe null-object default

Does the dependency vary per method call?
  YES → Method Injection (pass as parameter)
  NO  → Constructor Injection

Is the set of available implementations open-ended / plugin-based?
  YES → Service Locator acceptable at the plugin boundary only
  NO  → Never use Service Locator in domain logic

Is object graph large and cross-cutting (e.g., request scoping needed)?
  YES → DI Container; assemble at Composition Root; check scopes carefully
  NO  → Manual wiring at Composition Root is simpler and more explicit
```

## Cross-References

| Topic | Skill |
|-------|-------|
| Dependency Inversion Principle (the 'D' in SOLID) | `review-solid-clean-code` |
| Factory Method / Abstract Factory used in Composition Root | `design-patterns-creational-structural` |
| Singleton pattern and when DI replaces it | `design-patterns-creational-structural` |
| God Class / Feature Envy caused by hidden dependencies | `detect-code-smells` |
