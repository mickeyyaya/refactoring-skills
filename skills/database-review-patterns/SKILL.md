---
name: database-review-patterns
description: Use when reviewing a PR that touches database queries, ORM usage, schema migrations, or data access layers, or when diagnosing slow queries, data integrity failures, or connection issues in production
---

# Database Patterns for Code Review

## Overview

Database anti-patterns are among the most damaging defects in production systems: they are invisible in unit tests, appear only under realistic data volumes, and can degrade performance non-linearly. This catalog covers patterns a reviewer can identify from code alone — without running `EXPLAIN ANALYZE` or examining query logs.

Use this alongside `performance-anti-patterns` (N+1 and unbounded fetching at the performance level) and `security-patterns-code-review` (SQL injection in security context).

## When to Use

- A PR adds, modifies, or removes database queries or ORM calls
- A PR introduces a schema migration file
- A PR adds a new data model, relationship, or repository layer
- A service's query latency or error rate has increased

## Quick Reference

| Area | Red Flag | Severity | Fix |
|------|----------|----------|-----|
| **N+1 Query** | ORM call inside a loop | HIGH | Eager load / JOIN / DataLoader |
| **Missing Index** | WHERE/ORDER on non-indexed column | HIGH | Add targeted index |
| **SELECT \*** | `findAll()` without field projection | MEDIUM | Select specific columns |
| **Unbounded Query** | No LIMIT/pagination | HIGH | Cursor or offset pagination |
| **SQL Injection** | String interpolation in query | CRITICAL | Parameterized queries |
| **Missing Transaction** | Multi-step write without BEGIN/COMMIT | HIGH | Wrap in transaction |
| **Schema Design** | Missing FK, wrong type, excessive NULLs | HIGH | Normalize, add constraints |
| **Migration Safety** | NOT NULL without default, column drop in use | CRITICAL | Expand-contract migration |
| **Connection Pool** | New connection per request | HIGH | Module-scoped pool |
| **ORM Misuse** | Lazy load in loop, `.save()` on partial entity | MEDIUM | Explicit eager load / `.update()` |
| **Data Integrity** | No constraints, orphaned rows | HIGH | FK constraints, cascades |
| **Query Optimization** | No EXPLAIN, leading LIKE wildcard, correlated subquery | MEDIUM | Profile and index |

---

## Area 1: N+1 Query Problem

- **Description**: A query fetches N parent records, then issues one additional query per parent to load related data — N+1 total round trips.
- **Code Review Red Flags**:
  - Any ORM call (`.find`, `.findById`, `.getRelated`) inside a `for`, `forEach`, or `map`
  - `Promise.all(ids.map(id => repo.findOne(id)))` — parallel but still N queries
  - Relationship property accessed inside a loop without explicit eager loading

```typescript
// BEFORE — N+1: one query per order
const orders = await Order.findAll();
for (const order of orders) {
  order.customer = await Customer.findByPk(order.customerId);
}

// AFTER — single JOIN via eager loading
const orders = await Order.findAll({
  include: [{ model: Customer, as: 'customer' }],
});
```

- **Fix Strategy**: Use `include`/`joinedload`/`preload` for ORM relationships. For mixed data sources, use a DataLoader to batch per-tick. When loading by IDs, fetch all in one query: `WHERE id IN (...)`.

---

## Area 2: Missing Indexes

- **Description**: Queries filter, sort, or join on columns without an index. The database performs a full table scan and latency grows with row count.
- **Code Review Red Flags**:
  - New `WHERE col = ?` or `ORDER BY col` with no index in the migration
  - Foreign key columns without an index (many ORMs do not auto-create FK indexes)
  - Composite filters with only single-column indexes

```sql
-- BEFORE — full table scan on status
SELECT * FROM orders WHERE status = 'pending' ORDER BY created_at DESC;

-- AFTER — composite index covers both filter and sort
CREATE INDEX CONCURRENTLY idx_orders_status_created ON orders (status, created_at DESC);
SELECT id, customer_id, total FROM orders WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50;
```

- **Fix Strategy**: Add indexes for every `WHERE`, `JOIN ON`, and `ORDER BY` column on large tables. Use composite indexes (most selective column first). Prefer `CREATE INDEX CONCURRENTLY` to avoid table locks.

---

## Area 3: SELECT *

- **Description**: Queries fetch all columns when only a subset is needed, wasting bandwidth, memory, and blocking covering index use.
- **Code Review Red Flags**:
  - `SELECT *` in raw SQL or ORM `findAll()` with no `attributes`/`select` projection
  - Large BLOB or TEXT columns fetched when the caller only reads scalar fields
  - Serializing the full entity to JSON when the API response uses 3 fields

```typescript
// BEFORE — fetches all columns including large blob fields
const users = await User.findAll();
return users.map(u => ({ id: u.id, name: u.name }));

// AFTER — only fetch what is needed
const users = await User.findAll({ attributes: ['id', 'name'] });
return users;
```

- **Fix Strategy**: Enumerate required columns in every query or ORM projection. Derive the column list from the response schema. This enables covering indexes, where the database serves the query from the index alone.

---

## Area 4: Unbounded Queries

- **Description**: A query returns all matching rows with no upper bound, causing memory and latency to grow linearly with dataset size.
- **Code Review Red Flags**:
  - `findAll()` or `SELECT` without `LIMIT` or `take`
  - List endpoints with no pagination parameters
  - Accumulating all results in memory before returning

```typescript
// BEFORE — returns all rows
const invoices = await Invoice.findAll({ where: { tenantId } });

// AFTER — cursor-based pagination
const limit = Math.min(Number(req.query.limit ?? 50), 200);
const invoices = await Invoice.findAll({
  where: { tenantId, ...(cursor ? { id: { [Op.lt]: cursor } } : {}) },
  order: [['id', 'DESC']],
  limit,
});
const nextCursor = invoices.length === limit ? invoices.at(-1)!.id : null;
```

- **Fix Strategy**: Enforce a max page size at the API layer (e.g., 200 rows). Prefer cursor-based pagination over offset for large datasets. Use streaming or batch jobs for data exports.

---

## Area 5: SQL Injection

- **Description**: User-controlled input is interpolated into a SQL string. An attacker can exfiltrate data, bypass authentication, or destroy records.
- **Code Review Red Flags**:
  - Template literals with query params: `` `SELECT ... WHERE id = ${userId}` ``
  - `"... WHERE name = '" + req.body.name + "'"`
  - ORM escape hatches (`sequelize.query`, `db.raw`) with unparameterized input
  - Dynamic table or column names from user input without an allowlist

```typescript
// BEFORE — CRITICAL: injectable
const result = await db.query(`SELECT * FROM users WHERE email = '${req.body.email}'`);

// AFTER — parameterized
const result = await db.query('SELECT id, name, role FROM users WHERE email = $1', [req.body.email]);
```

- **Fix Strategy**: Always use parameterized queries or prepared statements. For dynamic identifiers (table/column names), validate against an explicit allowlist — parameterization does not protect identifiers.

---

## Area 6: Missing Transactions

- **Description**: A sequence of related writes executes without a transaction. A failure between steps leaves data in an inconsistent, partially-updated state.
- **Code Review Red Flags**:
  - Multiple `INSERT`/`UPDATE`/`DELETE` calls with no `BEGIN`/`COMMIT`
  - Error handler that catches an exception but does not roll back earlier writes
  - Financial operations where debit and credit are separate statements

```typescript
// BEFORE — partial failure leaves inconsistent state
await Account.decrement({ balance: amount }, { where: { id: fromId } });
await Account.increment({ balance: amount }, { where: { id: toId } }); // may never run

// AFTER — atomic transaction
await sequelize.transaction(async (t) => {
  await Account.decrement({ balance: amount }, { where: { id: fromId }, transaction: t });
  await Account.increment({ balance: amount }, { where: { id: toId }, transaction: t });
});
```

- **Fix Strategy**: Wrap any multi-step write in a single transaction. Choose the correct isolation level (`READ COMMITTED` for OLTP, `SERIALIZABLE` for financial consistency). Keep transactions short — never hold one open across a network call.

---

## Area 7: Schema Design Issues

- **Description**: Structural problems in the schema cause integrity violations or query inefficiency: denormalization, wrong types, missing foreign keys, or overuse of NULL.
- **Code Review Red Flags**:
  - Comma-separated IDs stored in a TEXT column instead of a join table
  - `INTEGER` status column with magic numbers instead of `ENUM`
  - Missing `FOREIGN KEY` constraints — orphaned records are possible
  - Nullable columns without a documented reason

```sql
-- BEFORE — denormalized, no FK
CREATE TABLE orders (id SERIAL PRIMARY KEY, product_ids TEXT, user_id INTEGER);

-- AFTER — normalized with FK and CHECK constraint
CREATE TABLE order_items (
  order_id  INTEGER NOT NULL REFERENCES orders(id)   ON DELETE CASCADE,
  product_id INTEGER NOT NULL REFERENCES products(id),
  quantity   INTEGER NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (order_id, product_id)
);
```

- **Fix Strategy**: Use the narrowest correct type. Enforce referential integrity with explicit `ON DELETE` behavior. Prefer `ENUM`/lookup tables over magic integers. Default to `NOT NULL`; require documented justification for every nullable column.

---

## Area 8: Migration Safety

- **Description**: Migrations that take locks, break running application code, or drop objects still in use cause downtime or data loss during deployment.
- **Code Review Red Flags**:
  - `ADD COLUMN col NOT NULL` without a `DEFAULT` — locks table in older Postgres
  - `DROP COLUMN` before the application stops referencing it
  - `CREATE INDEX` without `CONCURRENTLY` on a large table
  - Large backfill in a single transaction holding a lock for minutes

```sql
-- BEFORE — locks entire table
ALTER TABLE users ADD COLUMN verified BOOLEAN NOT NULL DEFAULT false;

-- AFTER — expand-contract (zero-downtime)
ALTER TABLE users ADD COLUMN verified BOOLEAN;                           -- Step 1: nullable, no lock
UPDATE users SET verified = false WHERE verified IS NULL AND id < 10001; -- Step 2: batch backfill
ALTER TABLE users ALTER COLUMN verified SET NOT NULL;                    -- Step 3: constrain after fill
ALTER TABLE users ALTER COLUMN verified SET DEFAULT false;
```

- **Fix Strategy**: Follow expand-contract: add nullable, backfill in batches, constrain, clean up in separate deployments. Always use `CREATE INDEX CONCURRENTLY`. Test migrations on a production-size dataset before deploying.

---

## Area 9: Connection Pool Exhaustion

- **Description**: Connections are created per request instead of acquired from a pool, or the pool is undersized. The database exhausts its connection limit under load.
- **Code Review Red Flags**:
  - `new Client(config)` or `createConnection()` inside a request handler
  - Connection opened but not released in a `finally` block
  - Pool `max` hardcoded to a small value without justification

```typescript
// BEFORE — new TCP connection per call
async function getProduct(id: string) {
  const client = new Client(config);
  await client.connect();
  const result = await client.query('SELECT * FROM products WHERE id = $1', [id]);
  await client.end();
  return result.rows[0];
}

// AFTER — shared pool initialized at module scope
const pool = new Pool({ max: 20, idleTimeoutMillis: 30_000 });
async function getProduct(id: string) {
  const { rows } = await pool.query('SELECT id, name, price FROM products WHERE id = $1', [id]);
  return rows[0];
}
```

- **Fix Strategy**: Create one pool per process at startup. Size `max` to `(DB max_connections / app instances) - headroom`. Monitor pool wait time — non-zero wait means the pool is undersized or connections are held too long.

---

## Area 10: ORM Misuse

- **Description**: Naive ORM usage silently triggers N+1 queries, corrupts data on partial saves, or adds raw SQL that undermines parameterization.
- **Code Review Red Flags**:
  - `.save()` on a partially-loaded entity (unloaded fields may be overwritten with NULL)
  - ORM used for aggregations that would be simpler and faster in a single SQL query
  - `sequelize.query(rawSql)` or `db.raw(rawSql)` with user input

```typescript
// BEFORE — partial save corrupts unloaded fields
const user = await User.findOne({ where: { id }, attributes: ['id', 'role'] });
user.role = 'admin';
await user.save(); // may NULL out name, email

// AFTER — targeted update
await User.update({ role: 'admin' }, { where: { id } });
```

- **Fix Strategy**: Enable query logging in development to see generated SQL. Use `.update()` for partial updates. For aggregations and bulk operations, write explicit SQL rather than loading all rows into the application.

---

## Area 11: Data Integrity

- **Description**: Missing constraints allow bugs or direct DB access to introduce orphaned records, duplicate rows, or invalid values.
- **Code Review Red Flags**:
  - `UNIQUE` enforced only at the application layer, not the database
  - Soft-delete table queried without `WHERE deleted_at IS NULL`
  - Junction table without a composite primary key (allows duplicate join rows)
  - No `CHECK` constraint on columns with known valid ranges

```sql
-- BEFORE — uniqueness in app only
CREATE TABLE user_emails (user_id INTEGER, email TEXT);

-- AFTER — database enforces uniqueness and FK
CREATE TABLE user_emails (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email   TEXT NOT NULL,
  UNIQUE (email)
);
-- Partial index for soft-delete filtering
CREATE INDEX idx_products_active ON products (id) WHERE deleted_at IS NULL;
```

- **Fix Strategy**: Enforce uniqueness, FK integrity, and value ranges at the database level. Use partial indexes for soft-delete tables. Document every `ON DELETE` behavior. Audit for orphaned records when FK constraints cannot be added retroactively.

---

## Area 12: Query Optimization

- **Description**: Queries are logically correct but structurally inefficient: leading wildcard LIKE, correlated subqueries, or missing covering indexes.
- **Code Review Red Flags**:
  - `LIKE '%term%'` prefix wildcard — B-tree index unusable
  - Correlated subquery in `WHERE` that re-executes per row
  - `EXPLAIN ANALYZE` not run on queries touching tables expected to exceed 10k rows

```sql
-- BEFORE — correlated subquery re-executes per row
SELECT u.id FROM users u WHERE (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) > 5;

-- AFTER — single JOIN + HAVING
SELECT u.id FROM users u JOIN orders o ON o.user_id = u.id GROUP BY u.id HAVING COUNT(o.id) > 5;
```

- **Fix Strategy**: Run `EXPLAIN (ANALYZE, BUFFERS)` on all new queries against realistic data. Replace leading-wildcard `LIKE` with full-text search or `pg_trgm`. Replace correlated subqueries with JOINs. Use covering indexes for read-heavy queries.

---

## Review Checklist by PR Type

| PR touches... | Check for... |
|---------------|-------------|
| ORM relationships | Lazy load in loop (N+1), missing `include`/`joinedload` |
| List/search endpoints | Missing `LIMIT`, no pagination, `SELECT *` |
| Raw SQL or query builder | String interpolation (injection), missing parameterization |
| Multi-step writes | Missing transaction, no rollback on error |
| Schema migration | NOT NULL without default, DROP before code updated, no CONCURRENTLY |
| New table or column | Missing FK, missing FK index, wrong data type |
| Soft-delete model | Missing `WHERE deleted_at IS NULL`, no partial index |
| New repository/DAO | Connection created per call, pool not reused |
| Aggregation query | ORM loading all rows to aggregate in application memory |

## Cross-References

| Related Skill | Relationship |
|---------------|-------------|
| `performance-anti-patterns` | Covers N+1 and unbounded fetching at the general performance level; this skill adds DB-specific depth |
| `security-patterns-code-review` | SQL injection as a security vulnerability with full attack surface context |
| `review-code-quality-process` | Workflow for conducting reviews that incorporate these checks |
| `anti-patterns-catalog` | Structural anti-patterns that co-occur with schema design issues |
| `error-handling-patterns` | Transaction rollback and connection error handling strategies |

## Common Review Mistakes

| Mistake | Correct Approach |
|---------|-----------------|
| Flagging every `findAll()` as unbounded | Only flag when the table can grow large and the caller applies no domain filter |
| Requiring indexes on every column | Indexes have write overhead; add them only for WHERE, JOIN, and ORDER BY on large tables |
| Treating ORM use for aggregations as always wrong | ORMs are fine for CRUD; flag only when the ORM generates an obviously worse plan |
| Requiring transactions for single-statement writes | Single SQL statements are atomic; transactions add value only for multi-statement sequences |
| Flagging LIKE queries without checking table size | A full scan on a 500-row lookup table is acceptable; flag only when the table is expected to scale |
