---
name: database-review-patterns
description: Use when reviewing a PR that touches database queries, ORM usage, schema migrations, or data access layers, or when diagnosing slow queries, data integrity failures, or connection issues in production
---

# Database Patterns for Code Review

## Overview

Database anti-patterns are among the most damaging production defects: invisible in unit tests, appearing only under realistic data volumes, degrading performance non-linearly. This catalog covers patterns identifiable from code alone.

Use alongside `performance-anti-patterns` (N+1 and unbounded fetching) and `security-patterns-code-review` (SQL injection).

## Quick Reference

| Area | Red Flag | Severity | Fix |
|------|----------|----------|-----|
| **N+1 Query** | ORM call inside a loop | HIGH | Eager load / JOIN / DataLoader |
| **Missing Index** | WHERE/ORDER on non-indexed column | HIGH | Add targeted index |
| **SELECT \*** | `findAll()` without projection | MEDIUM | Select specific columns |
| **Unbounded Query** | No LIMIT/pagination | HIGH | Cursor or offset pagination |
| **SQL Injection** | String interpolation in query | CRITICAL | Parameterized queries |
| **Missing Transaction** | Multi-step write without BEGIN/COMMIT | HIGH | Wrap in transaction |
| **Schema Design** | Missing FK, wrong type, excessive NULLs | HIGH | Normalize, add constraints |
| **Migration Safety** | NOT NULL without default, column drop in use | CRITICAL | Expand-contract migration |
| **Connection Pool** | New connection per request | HIGH | Module-scoped pool |
| **ORM Misuse** | Lazy load in loop, `.save()` on partial entity | MEDIUM | Explicit eager load / `.update()` |
| **Data Integrity** | No constraints, orphaned rows | HIGH | FK constraints, cascades |
| **Query Optimization** | Leading LIKE wildcard, correlated subquery | MEDIUM | Profile and index |

---

## Area 1: N+1 Query Problem

**Red Flags:** ORM call inside `for`/`forEach`/`map`; `Promise.all(ids.map(id => repo.findOne(id)))`; relationship accessed in loop without eager loading.

```typescript
// BEFORE — N+1: one query per order
const orders = await Order.findAll();
for (const order of orders) {
  order.customer = await Customer.findByPk(order.customerId);
}

// AFTER — single JOIN
const orders = await Order.findAll({
  include: [{ model: Customer, as: 'customer' }],
});
```

**Fix:** Use `include`/`joinedload`/`preload` for relationships. Use DataLoader for mixed sources. Fetch by IDs: `WHERE id IN (...)`.

---

## Area 2: Missing Indexes

**Red Flags:** New `WHERE`/`ORDER BY` with no index in migration; FK columns without index; composite filters with only single-column indexes.

```sql
-- BEFORE — full table scan
SELECT * FROM orders WHERE status = 'pending' ORDER BY created_at DESC;

-- AFTER — composite index
CREATE INDEX CONCURRENTLY idx_orders_status_created ON orders (status, created_at DESC);
SELECT id, customer_id, total FROM orders WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50;
```

**Fix:** Index every `WHERE`, `JOIN ON`, `ORDER BY` on large tables. Most selective column first. Use `CONCURRENTLY` to avoid locks.

---

## Area 3: SELECT *

**Red Flags:** `SELECT *` or `findAll()` with no projection; large BLOB/TEXT fetched when caller reads scalar fields.

```typescript
// BEFORE
const users = await User.findAll();
return users.map(u => ({ id: u.id, name: u.name }));

// AFTER
const users = await User.findAll({ attributes: ['id', 'name'] });
```

**Fix:** Enumerate required columns. Derive from response schema. Enables covering indexes.

---

## Area 4: Unbounded Queries

**Red Flags:** `findAll()` without `LIMIT`; list endpoints with no pagination; accumulating all results in memory.

```typescript
// BEFORE
const invoices = await Invoice.findAll({ where: { tenantId } });

// AFTER — cursor-based pagination
const limit = Math.min(Number(req.query.limit ?? 50), 200);
const invoices = await Invoice.findAll({
  where: { tenantId, ...(cursor ? { id: { [Op.lt]: cursor } } : {}) },
  order: [['id', 'DESC']],
  limit,
});
```

**Fix:** Enforce max page size (e.g., 200). Prefer cursor pagination for large datasets. Use streaming for exports.

---

## Area 5: SQL Injection

**Red Flags:** Template literals with query params; string concatenation into SQL; ORM escape hatches with unparameterized input; dynamic identifiers from user input without allowlist.

```typescript
// BEFORE — injectable
const result = await db.query(`SELECT * FROM users WHERE email = '${req.body.email}'`);

// AFTER — parameterized
const result = await db.query('SELECT id, name, role FROM users WHERE email = $1', [req.body.email]);
```

**Fix:** Always use parameterized queries. For dynamic identifiers, validate against an explicit allowlist.

---

## Area 6: Missing Transactions

**Red Flags:** Multiple writes with no `BEGIN`/`COMMIT`; error handler that catches without rollback; financial operations with separate debit/credit statements.

```typescript
// BEFORE — partial failure leaves inconsistent state
await Account.decrement({ balance: amount }, { where: { id: fromId } });
await Account.increment({ balance: amount }, { where: { id: toId } });

// AFTER — atomic
await sequelize.transaction(async (t) => {
  await Account.decrement({ balance: amount }, { where: { id: fromId }, transaction: t });
  await Account.increment({ balance: amount }, { where: { id: toId }, transaction: t });
});
```

**Fix:** Wrap multi-step writes in a transaction. Choose correct isolation level. Keep transactions short.

---

## Area 7: Schema Design Issues

**Red Flags:** Comma-separated IDs in TEXT instead of join table; INTEGER status with magic numbers; missing FK constraints; nullable columns without documented reason.

```sql
-- BEFORE — denormalized, no FK
CREATE TABLE orders (id SERIAL PRIMARY KEY, product_ids TEXT, user_id INTEGER);

-- AFTER — normalized with FK
CREATE TABLE order_items (
  order_id  INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id INTEGER NOT NULL REFERENCES products(id),
  quantity   INTEGER NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (order_id, product_id)
);
```

**Fix:** Narrowest correct type. Explicit FK with `ON DELETE` behavior. `ENUM`/lookup over magic integers. Default `NOT NULL`.

---

## Area 8: Migration Safety

**Red Flags:** `ADD COLUMN NOT NULL` without `DEFAULT`; `DROP COLUMN` before app stops referencing it; `CREATE INDEX` without `CONCURRENTLY`; large backfill in single transaction.

```sql
-- Expand-contract (zero-downtime)
ALTER TABLE users ADD COLUMN verified BOOLEAN;                           -- Step 1: nullable
UPDATE users SET verified = false WHERE verified IS NULL AND id < 10001; -- Step 2: batch backfill
ALTER TABLE users ALTER COLUMN verified SET NOT NULL;                    -- Step 3: constrain
ALTER TABLE users ALTER COLUMN verified SET DEFAULT false;
```

**Fix:** Expand-contract pattern. Backfill in batches. `CREATE INDEX CONCURRENTLY`. Test on production-size data.

---

## Area 9: Connection Pool Exhaustion

**Red Flags:** `new Client(config)` inside request handler; connection not released in `finally`; pool `max` hardcoded without justification.

```typescript
// BEFORE — new connection per call
async function getProduct(id: string) {
  const client = new Client(config);
  await client.connect();
  const result = await client.query('SELECT * FROM products WHERE id = $1', [id]);
  await client.end();
  return result.rows[0];
}

// AFTER — shared pool
const pool = new Pool({ max: 20, idleTimeoutMillis: 30_000 });
async function getProduct(id: string) {
  const { rows } = await pool.query('SELECT id, name, price FROM products WHERE id = $1', [id]);
  return rows[0];
}
```

**Fix:** One pool per process at startup. Size: `(DB max_connections / app instances) - headroom`. Monitor pool wait time.

---

## Area 10: ORM Misuse

**Red Flags:** `.save()` on partially-loaded entity; ORM for aggregations better done in SQL; `sequelize.query(rawSql)` with user input.

```typescript
// BEFORE — partial save corrupts unloaded fields
const user = await User.findOne({ where: { id }, attributes: ['id', 'role'] });
user.role = 'admin';
await user.save();

// AFTER — targeted update
await User.update({ role: 'admin' }, { where: { id } });
```

**Fix:** Enable query logging in dev. Use `.update()` for partial updates. Write SQL for aggregations and bulk ops.

---

## Area 11: Data Integrity

**Red Flags:** `UNIQUE` enforced only in app; soft-delete queries missing `WHERE deleted_at IS NULL`; junction table without composite PK; no `CHECK` on bounded columns.

```sql
-- BEFORE
CREATE TABLE user_emails (user_id INTEGER, email TEXT);

-- AFTER
CREATE TABLE user_emails (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email   TEXT NOT NULL,
  UNIQUE (email)
);
CREATE INDEX idx_products_active ON products (id) WHERE deleted_at IS NULL;
```

**Fix:** Enforce uniqueness, FK, and value ranges at DB level. Partial indexes for soft-delete. Document `ON DELETE` behavior.

---

## Area 12: Query Optimization

**Red Flags:** `LIKE '%term%'`; correlated subquery in `WHERE`; no `EXPLAIN` on queries for large tables.

```sql
-- BEFORE — correlated subquery
SELECT u.id FROM users u WHERE (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) > 5;

-- AFTER — JOIN + HAVING
SELECT u.id FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.id HAVING COUNT(o.id) > 5;
```

**Fix:** Run `EXPLAIN (ANALYZE, BUFFERS)` on new queries. Use full-text search or `pg_trgm` over leading-wildcard LIKE. Replace correlated subqueries with JOINs.

---

## Review Checklist by PR Type

| PR touches... | Check for... |
|---------------|-------------|
| ORM relationships | N+1, missing `include`/`joinedload` |
| List/search endpoints | Missing `LIMIT`, no pagination, `SELECT *` |
| Raw SQL | String interpolation, missing parameterization |
| Multi-step writes | Missing transaction, no rollback |
| Schema migration | NOT NULL without default, no CONCURRENTLY |
| New table/column | Missing FK, missing FK index, wrong type |
| Soft-delete model | Missing `WHERE deleted_at IS NULL`, no partial index |
| New repository/DAO | Connection per call, pool not reused |
| Aggregation | ORM loading all rows to aggregate in app memory |

## Cross-References

| Related Skill | Relationship |
|---------------|-------------|
| `performance-anti-patterns` | N+1 and unbounded fetching at general performance level |
| `security-patterns-code-review` | SQL injection with full attack surface context |
| `review-code-quality-process` | Workflow for conducting reviews |
| `anti-patterns-catalog` | Structural anti-patterns co-occurring with schema issues |
| `error-handling-patterns` | Transaction rollback and connection error handling |

## Common Review Mistakes

| Mistake | Correct Approach |
|---------|-----------------|
| Flagging every `findAll()` as unbounded | Only flag when table can grow large and no domain filter applied |
| Requiring indexes on every column | Add only for WHERE, JOIN, ORDER BY on large tables |
| Treating ORM aggregations as always wrong | Flag only when ORM generates obviously worse plan |
| Requiring transactions for single writes | Single SQL statements are already atomic |
| Flagging LIKE on small lookup tables | Flag only when table is expected to scale |
