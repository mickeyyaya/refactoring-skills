---
name: multi-tenancy-patterns
description: Use when designing or reviewing multi-tenant systems — covers tenant isolation strategies (RLS, schema-per-tenant, DB-per-tenant), tenant context propagation, tenant-aware caching, tenant lifecycle management, shared vs isolated infrastructure tradeoffs, and multi-tenant anti-patterns across TypeScript, Go, Python, and SQL/PostgreSQL
---

# Multi-Tenancy Patterns

## Overview

Multi-tenant systems serve multiple customers (tenants) from a single deployment while keeping their data and configuration isolated. The hard part is not handling one tenant — it is ensuring that tenant A can never read, write, or affect tenant B's data, even when they share the same database, cache, and application servers.

**When to use:** Designing SaaS platforms; reviewing any code that queries a shared database; evaluating caching layers; building onboarding or offboarding workflows; assessing the blast radius of a bug that touches tenant data.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Row-Level Security (RLS) | Database enforces tenant filter at query time | Missing `tenant_id` predicate, RLS policy disabled |
| Schema-per-Tenant | Each tenant owns a dedicated PostgreSQL schema | Schema name built from user input (injection risk) |
| DB-per-Tenant | Strongest isolation; each tenant gets a separate database | Connection pool exhaustion, cross-tenant migration drift |
| Tenant Context Propagation | AsyncLocalStorage / goroutine-local store carries tenant ID through call stack | Missing middleware, context lost across async boundaries |
| ORM Tenant Scope | ORM automatically injects `WHERE tenant_id = ?` | Global scope disabled in admin paths, scope skipped in raw queries |
| Tenant-Aware Caching | Cache key includes tenant namespace | Cache key missing tenant prefix, cross-tenant cache poisoning |
| Tenant Lifecycle | Provision, migrate, and offboard tenants as atomic operations | Schema created but migration not run, data not purged on offboard |
| Shared vs Isolated | Cost/compliance tradeoff matrix for infrastructure sharing | No documented decision; isolation level inconsistent across services |

---

## Patterns in Detail

### 1. Tenant Isolation Strategies

Choose an isolation model based on compliance requirements, cost targets, and operational complexity. The three canonical levels are Row-Level Security (RLS), schema-per-tenant, and database-per-tenant.

**Red Flags:**
- Queries against a shared table with no `tenant_id` filter
- RLS policies defined but `SET LOCAL app.tenant_id` never called
- Schema name or database name derived from raw user input without validation
- Mixing isolation models within the same service without clear documentation

#### Row-Level Security (PostgreSQL)

RLS enforces isolation inside the database itself. Even if application code forgets the filter, the database rejects the query.

```sql
-- Enable RLS on the shared table
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;

-- Policy: rows visible only when tenant_id matches the session variable
CREATE POLICY tenant_isolation ON orders
  USING (tenant_id = current_setting('app.tenant_id')::uuid);

-- Application sets the session variable at the start of each request
-- (called from connection middleware before any query runs)
SET LOCAL app.tenant_id = '550e8400-e29b-41d4-a716-446655440000';
```

```sql
-- Verify policy is active (run in code review or CI audit)
SELECT tablename, policyname, cmd, qual
FROM pg_policies
WHERE tablename = 'orders';
```

**TypeScript — Express middleware setting the session variable:**
```typescript
import { Pool } from 'pg';

async function tenantMiddleware(
  req: Request,
  res: Response,
  next: NextFunction,
  pool: Pool
): Promise<void> {
  const tenantId = req.headers['x-tenant-id'];
  if (!tenantId || typeof tenantId !== 'string') {
    res.status(401).json({ error: 'Missing tenant context' });
    return;
  }
  // Validate UUID format before injecting into the session
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!UUID_RE.test(tenantId)) {
    res.status(400).json({ error: 'Invalid tenant ID format' });
    return;
  }
  const client = await pool.connect();
  try {
    await client.query(`SET LOCAL app.tenant_id = $1`, [tenantId]);
    res.locals.dbClient = client;
    next();
  } catch (err) {
    client.release();
    next(err);
  }
}
```

#### Schema-per-Tenant

Each tenant gets a dedicated PostgreSQL schema (`tenant_<id>.orders`). Strong isolation; moderate operational overhead.

```sql
-- Provisioning a new tenant schema
CREATE SCHEMA IF NOT EXISTS tenant_acme;
CREATE TABLE tenant_acme.orders (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL,
  total       NUMERIC(12,2) NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);
```

**Python — safe schema routing (never interpolate raw user input):**
```python
import re
import psycopg2

SCHEMA_RE = re.compile(r'^[a-z][a-z0-9_]{1,62}$')

def get_tenant_connection(tenant_slug: str) -> psycopg2.extensions.connection:
    """Return a connection scoped to the tenant schema.
    Raises ValueError if slug does not match allow-list pattern.
    """
    if not SCHEMA_RE.match(tenant_slug):
        raise ValueError(f"Invalid tenant slug: {tenant_slug!r}")
    schema = f"tenant_{tenant_slug}"
    conn = psycopg2.connect(dsn=DATABASE_URL)
    # search_path is set via parameter binding, not string interpolation
    conn.cursor().execute("SET search_path TO %s, public", (schema,))
    return conn
```

#### Database-per-Tenant

Maximum isolation. Each tenant maps to a separate database URL. Required for strict compliance (HIPAA, financial data segregation).

```typescript
// tenant-registry.ts — immutable lookup, never mutated in place
type TenantDb = { tenantId: string; dbUrl: string; poolSize: number };

class TenantRegistry {
  private readonly registry: ReadonlyMap<string, TenantDb>;

  constructor(entries: TenantDb[]) {
    this.registry = new Map(entries.map(e => [e.tenantId, e]));
  }

  getDbUrl(tenantId: string): string {
    const entry = this.registry.get(tenantId);
    if (!entry) throw new Error(`Unknown tenant: ${tenantId}`);
    return entry.dbUrl;
  }
}
```

---

### 2. Tenant Context Propagation

Every function in the call stack must have access to the current tenant ID without passing it as an explicit parameter through every layer. Use `AsyncLocalStorage` (Node.js) or `context.Context` (Go) to carry it implicitly.

**Red Flags:**
- Tenant ID passed as a plain function parameter through 5+ layers — coupling every signature to tenancy
- Context lost when crossing a `new Worker()`, `setTimeout`, or untracked promise
- Admin background jobs that inadvertently inherit a tenant context from a previous request
- Middleware that sets the context but does not clear it on response end

**TypeScript — AsyncLocalStorage:**
```typescript
import { AsyncLocalStorage } from 'async_hooks';

interface TenantContext {
  tenantId: string;
  plan: 'free' | 'pro' | 'enterprise';
}

// Singleton store — exported so any module can read it
export const tenantStore = new AsyncLocalStorage<TenantContext>();

// Express middleware — wraps each request in its own async context
export function tenantContextMiddleware(
  req: Request,
  _res: Response,
  next: NextFunction
): void {
  const tenantId = req.headers['x-tenant-id'] as string | undefined;
  if (!tenantId) { next(new Error('Missing x-tenant-id header')); return; }

  const ctx: TenantContext = { tenantId, plan: resolvePlan(tenantId) };
  tenantStore.run(ctx, next);  // all downstream code in this request sees ctx
}

// Any service layer reads context without knowing about HTTP
export function getCurrentTenantId(): string {
  const ctx = tenantStore.getStore();
  if (!ctx) throw new Error('No tenant context — is middleware applied?');
  return ctx.tenantId;
}
```

**Go — context.Context propagation:**
```go
type contextKey string

const tenantKey contextKey = "tenantID"

// SetTenant returns a new context with the tenant ID embedded.
func SetTenant(ctx context.Context, tenantID string) context.Context {
    return context.WithValue(ctx, tenantKey, tenantID)
}

// GetTenant extracts the tenant ID; returns empty string if missing.
func GetTenant(ctx context.Context) (string, bool) {
    id, ok := ctx.Value(tenantKey).(string)
    return id, ok && id != ""
}

// HTTP middleware for Chi/stdlib
func TenantMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        tenantID := r.Header.Get("X-Tenant-ID")
        if tenantID == "" {
            http.Error(w, "missing tenant", http.StatusUnauthorized)
            return
        }
        next.ServeHTTP(w, r.WithContext(SetTenant(r.Context(), tenantID)))
    })
}
```

**ORM Scope (TypeORM — TypeScript):**
```typescript
// Base repository always injects tenant filter — raw queries bypass this, so ban them
export class TenantAwareRepository<T extends { tenantId: string }> {
  constructor(
    private readonly repo: Repository<T>,
    private readonly store: AsyncLocalStorage<TenantContext>
  ) {}

  private get tenantId(): string {
    return this.store.getStore()?.tenantId ?? (() => { throw new Error('No tenant context'); })();
  }

  findAll(): Promise<T[]> {
    return this.repo.find({ where: { tenantId: this.tenantId } as any });
  }

  findById(id: string): Promise<T | null> {
    return this.repo.findOne({ where: { id, tenantId: this.tenantId } as any });
  }
}
```

---

### 3. Tenant-Aware Caching

Cached values must never be served to a different tenant. The simplest fix is namespacing every cache key with the tenant ID. More complex systems use per-tenant cache partitions.

**Red Flags:**
- Cache key based on resource ID alone: `cache.get('product:123')` — the same key is shared across all tenants
- Cache warmed by one tenant and read by another (cross-tenant cache poisoning)
- Cache TTL not aligned with tenant plan (free tier hitting paid-tier cached data)
- Cache invalidation on data delete does not include tenant prefix, leaving stale data for other tenants

**TypeScript — namespaced cache key helper:**
```typescript
// Always use this helper; never build cache keys by hand
function tenantCacheKey(resource: string, id: string): string {
  const tenantId = getCurrentTenantId();  // from AsyncLocalStorage
  return `t:${tenantId}:${resource}:${id}`;
}

async function getProduct(productId: string): Promise<Product> {
  const key = tenantCacheKey('product', productId);
  const cached = await redis.get(key);
  if (cached) return JSON.parse(cached) as Product;

  const product = await db.products.findById(productId, getCurrentTenantId());
  await redis.set(key, JSON.stringify(product), { EX: 300 });
  return product;
}

// Invalidation also uses the namespaced key
async function deleteProduct(productId: string): Promise<void> {
  await db.products.delete(productId, getCurrentTenantId());
  await redis.del(tenantCacheKey('product', productId));
}
```

**Python — Redis cache with tenant namespace:**
```python
from functools import wraps
import json, redis

_redis = redis.Redis.from_url(REDIS_URL)

def tenant_cache(ttl_seconds: int = 300):
    """Decorator that namespaces cache keys by current tenant."""
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            tenant_id = get_current_tenant_id()  # from request-local storage
            key = f"t:{tenant_id}:{fn.__name__}:{args}:{sorted(kwargs.items())}"
            raw = _redis.get(key)
            if raw:
                return json.loads(raw)
            result = fn(*args, **kwargs)
            _redis.setex(key, ttl_seconds, json.dumps(result))
            return result
        return wrapper
    return decorator

@tenant_cache(ttl_seconds=60)
def get_user_settings(user_id: str) -> dict:
    return db.query("SELECT * FROM user_settings WHERE id = %s", (user_id,))
```

**Go — tenant-scoped cache:**
```go
type TenantCache struct {
    client *redis.Client
}

func (c *TenantCache) key(ctx context.Context, resource, id string) (string, error) {
    tenantID, ok := GetTenant(ctx)
    if !ok {
        return "", fmt.Errorf("tenant cache: no tenant in context")
    }
    return fmt.Sprintf("t:%s:%s:%s", tenantID, resource, id), nil
}

func (c *TenantCache) Get(ctx context.Context, resource, id string) (string, error) {
    k, err := c.key(ctx, resource, id)
    if err != nil { return "", err }
    return c.client.Get(ctx, k).Result()
}
```

---

### 4. Tenant Lifecycle Management

Tenant lifecycle has three phases: provisioning (create resources), migration (keep schemas in sync), and offboarding (delete or archive data). Each phase must be atomic or idempotent to handle partial failures.

**Red Flags:**
- Provisioning creates a schema but does not run migrations — tenant starts with a stale schema
- Offboarding marks a tenant inactive in the registry but leaves rows in the shared database
- No audit log for lifecycle events — cannot prove data was deleted for compliance
- Migration applied globally to all tenants at once — no canary or per-tenant rollout

**TypeScript — provisioning service:**
```typescript
interface TenantProvisionResult {
  tenantId: string;
  schemaName: string;
  createdAt: Date;
}

async function provisionTenant(
  slug: string,
  plan: 'free' | 'pro' | 'enterprise'
): Promise<TenantProvisionResult> {
  const tenantId = crypto.randomUUID();
  const schemaName = `tenant_${slug.replace(/[^a-z0-9]/g, '_')}`;

  // All steps in a transaction — if any step fails, everything rolls back
  return db.transaction(async (tx) => {
    await tx.query(`CREATE SCHEMA IF NOT EXISTS ${schemaName}`);
    await runMigrations(tx, schemaName);           // apply all pending migrations
    await tx.query(
      `INSERT INTO tenant_registry (id, slug, schema_name, plan) VALUES ($1,$2,$3,$4)`,
      [tenantId, slug, schemaName, plan]
    );
    await auditLog.record({ event: 'tenant.provisioned', tenantId, schemaName });
    return { tenantId, schemaName, createdAt: new Date() };
  });
}
```

**TypeScript — offboarding service:**
```typescript
async function offboardTenant(tenantId: string): Promise<void> {
  const tenant = await tenantRegistry.findById(tenantId);
  if (!tenant) throw new Error(`Tenant not found: ${tenantId}`);

  await db.transaction(async (tx) => {
    // 1. Export data snapshot for compliance archive before deletion
    await exportTenantData(tenantId, tenant.schemaName);

    // 2. Drop schema (cascades to all tables)
    await tx.query(`DROP SCHEMA IF EXISTS ${tenant.schemaName} CASCADE`);

    // 3. Remove from registry
    await tx.query(`DELETE FROM tenant_registry WHERE id = $1`, [tenantId]);

    // 4. Purge tenant-namespaced cache entries
    await redis.eval(
      `for _,k in ipairs(redis.call('keys', ARGV[1])) do redis.call('del',k) end`,
      0, `t:${tenantId}:*`
    );

    // 5. Audit trail — never delete this record
    await auditLog.record({ event: 'tenant.offboarded', tenantId, timestamp: new Date() });
  });
}
```

**Python — per-tenant migration runner:**
```python
from alembic.config import Config
from alembic import command

def run_tenant_migrations(schema_name: str) -> None:
    """Apply pending Alembic migrations for a single tenant schema."""
    alembic_cfg = Config("alembic.ini")
    alembic_cfg.set_main_option("version_locations", "migrations/tenant")
    alembic_cfg.set_main_option(
        "sqlalchemy.url",
        f"{DATABASE_URL}?options=-csearch_path%3D{schema_name}"
    )
    command.upgrade(alembic_cfg, "head")
```

---

### 5. Shared vs Isolated Infrastructure Tradeoffs

No single isolation model fits all use cases. Document the tradeoff explicitly; do not let it emerge by accident.

**Red Flags:**
- No documented isolation level — developers make inconsistent choices across services
- Compliance-regulated tenants (HIPAA, SOC 2) sharing infrastructure with unregulated tenants
- DB-per-tenant with hundreds of tenants and a single app server — connection pool exhaustion
- Schema-per-tenant with no migration tooling — schemas drift out of sync over time

| Model | Isolation | Cost | Operational Complexity | Good For |
|-------|-----------|------|----------------------|----------|
| Shared table + RLS | Low–Medium | Low | Low | Early-stage SaaS, low compliance |
| Schema-per-tenant | Medium | Medium | Medium | Mid-market SaaS, moderate compliance |
| DB-per-tenant | High | High | High | Enterprise, HIPAA, financial data |
| Hybrid | Configurable per tier | Variable | High | Tiered SaaS (free=shared, enterprise=isolated) |

**TypeScript — hybrid router selecting isolation level by tenant plan:**
```typescript
type IsolationLevel = 'shared-rls' | 'schema' | 'dedicated-db';

function resolveIsolation(plan: string): IsolationLevel {
  switch (plan) {
    case 'enterprise': return 'dedicated-db';
    case 'pro':        return 'schema';
    default:           return 'shared-rls';
  }
}

async function getDbConnection(tenantId: string): Promise<PoolClient | Connection> {
  const tenant = await tenantRegistry.findById(tenantId);
  const level = resolveIsolation(tenant.plan);

  switch (level) {
    case 'dedicated-db':
      return dedicatedDbPool.get(tenantId).connect();
    case 'schema':
      return schemaPool.connect().then(c => {
        c.query(`SET search_path TO ${tenant.schemaName}, public`);
        return c;
      });
    case 'shared-rls':
      return sharedPool.connect().then(c => {
        c.query(`SET LOCAL app.tenant_id = $1`, [tenantId]);
        return c;
      });
  }
}
```

---

### 6. Multi-Tenant Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Unscoped Query** | `SELECT * FROM orders` — no tenant filter | Always include `WHERE tenant_id = ?` or rely on RLS |
| **Cross-Tenant Data Leak** | Bug allows tenant A to access tenant B's records | Use RLS + integration tests that assert cross-tenant access returns 403/empty |
| **Hardcoded Tenant IDs** | `if (tenantId === 'acme-corp') { specialLogic() }` | Use tenant feature flags or per-tenant config table |
| **Missing Context Guard** | Background job runs without a tenant context and queries all rows | Always set or validate tenant context before any DB operation |
| **Global Cache Namespace** | Cache key is `product:${id}` — shared across tenants | Prefix every key: `t:${tenantId}:product:${id}` |
| **Schema Name from User Input** | `SET search_path TO ${req.body.tenant}` — SQL injection | Validate slug against allowlist regex before building schema name |
| **Silent RLS Bypass** | Admin queries run as superuser, bypassing RLS policies | Create a dedicated limited-privilege role; use superuser only for migrations |
| **Migration on All Tenants at Once** | Running `ALTER TABLE` across 500 schemas simultaneously — table locks | Use a batched migration runner with progress tracking and rollback |

**Cross-tenant data leak — integration test pattern (TypeScript):**
```typescript
describe('tenant isolation', () => {
  it('tenant A cannot read tenant B orders', async () => {
    // Arrange: seed an order for tenant B
    await seedOrder({ tenantId: TENANT_B_ID, id: ORDER_ID });

    // Act: authenticated request as tenant A
    const res = await request(app)
      .get(`/orders/${ORDER_ID}`)
      .set('x-tenant-id', TENANT_A_ID);

    // Assert: 404 (not 403) — do not confirm resource existence to other tenants
    expect(res.status).toBe(404);
  });
});
```

**Hardcoded tenant ID — before/after:**
```typescript
// WRONG: special-casing a tenant in code
function getFeatureFlags(tenantId: string) {
  if (tenantId === 'acme-corp') return { betaDashboard: true };
  return { betaDashboard: false };
}

// CORRECT: feature flags stored per tenant in config table
async function getFeatureFlags(tenantId: string): Promise<FeatureFlags> {
  const row = await db.query(
    `SELECT flags FROM tenant_config WHERE tenant_id = $1`,
    [tenantId]
  );
  return row?.flags ?? DEFAULT_FLAGS;
}
```

**SQL — detect unscoped queries (CI linting rule example):**
```sql
-- Audit query: find tables that have a tenant_id column but no RLS policy
SELECT c.relname AS table_name
FROM pg_class c
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
LEFT JOIN pg_policy p ON p.polrelid = c.oid
WHERE c.relkind = 'r'
  AND p.polname IS NULL
ORDER BY c.relname;
```

---

### 7. Tenant-Aware Observability

Logs, metrics, and traces must be annotated with tenant context so incidents can be scoped to a single tenant without exposing other tenants' data.

**Red Flags:**
- Logs contain no tenant ID — impossible to filter an incident to one tenant
- Metrics aggregated globally — cannot tell which tenant is causing a spike
- Trace spans missing tenant tag — distributed trace crosses tenant boundaries silently

**TypeScript — structured logging with tenant context:**
```typescript
import pino from 'pino';

const baseLogger = pino({ level: 'info' });

// Child logger binds tenant ID to every log line in this request
export function getLogger(): pino.Logger {
  const ctx = tenantStore.getStore();
  return ctx
    ? baseLogger.child({ tenantId: ctx.tenantId })
    : baseLogger;
}

// Usage — no manual tenantId threading required
const log = getLogger();
log.info({ orderId }, 'Order created');
// Output: { "tenantId": "acme-corp", "orderId": "...", "msg": "Order created" }
```

**Go — OpenTelemetry span with tenant attribute:**
```go
func CreateOrder(ctx context.Context, order Order) error {
    tenantID, _ := GetTenant(ctx)

    ctx, span := otel.Tracer("orders").Start(ctx, "CreateOrder")
    defer span.End()

    span.SetAttributes(attribute.String("tenant.id", tenantID))

    if err := db.InsertOrder(ctx, order); err != nil {
        span.RecordError(err)
        return fmt.Errorf("CreateOrder tenant=%s: %w", tenantID, err)
    }
    return nil
}
```

---

## Cross-References

- `auth-authz-patterns` — JWT claims and RBAC scoping: tenant ID should be a verified claim in the JWT, not a raw header
- `database-review-patterns` — Query review checklist: all queries against shared tables must include tenant predicate
- `security-patterns-code-review` — SQL injection and privilege escalation: schema-per-tenant slug validation and RLS bypass via superuser role
- `caching-strategies` — Cache invalidation patterns: tenant-namespaced keys and TTL strategy per plan tier
- `observability-patterns` — Structured logging and distributed tracing: tenant ID as a required trace attribute
