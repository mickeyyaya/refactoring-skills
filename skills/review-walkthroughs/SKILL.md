---
name: review-walkthroughs
description: Use when you need end-to-end examples of the full code review diagnostic flow — each walkthrough traces: detect the issue, calibrate confidence and severity, write the review comment, and decide the verdict. Covers security, performance, AI-generated code, and concurrency scenarios across Python, Go, TypeScript, and Java.
---

# Review Walkthroughs

## Overview

Each walkthrough follows the full review flow:

1. **Detect** — identify the issue using the relevant skill (security, performance, language-specific)
2. **Calibrate** — assign confidence level (C1–C4) and severity using `review-accuracy-calibration`
3. **Write feedback** — apply the comment template from `review-feedback-quality`
4. **Decide** — Request Changes, Approve with Comment, or Approve

Skills loaded in each scenario are listed explicitly. Use these walkthroughs to calibrate your own review process or to onboard reviewers to the full diagnostic flow.

## Scenario Summary

| # | Language | Issue Type | Confidence | Severity | Verdict |
|---|----------|-----------|------------|----------|---------|
| 1 | Python | SQL Injection | C4 Certain | CRITICAL | Request Changes |
| 2 | Go | N+1 Query / performance | C3 High | HIGH | Request Changes |
| 3 | TypeScript | AI-generated: hallucinated API, stale closure, missing error handling | C3 High | HIGH | Request Changes |
| 4 | Java | Unsynchronized shared state / concurrency | C4 Certain | CRITICAL | Request Changes |

### Scenario 1: Security Bug in Python Flask API

**Context:** A PR adds a `/users/search` endpoint to a Flask API. The endpoint accepts a query parameter and fetches matching users from a PostgreSQL database.

**Skills loaded:** `security-patterns-code-review`, `review-accuracy-calibration`, `review-feedback-quality`, `python-review-patterns`

#### Step 1: Detect

Scanning the endpoint handler for injection vectors — user input flows directly into a SQL string.

```python
# Before: vulnerable endpoint
from flask import Flask, request
import psycopg2

app = Flask(__name__)
conn = psycopg2.connect("dbname=myapp user=postgres")

@app.route("/users/search")
def search_users():
    query = request.args.get("q", "")
    cursor = conn.cursor()
    # VULNERABILITY: string interpolation in SQL
    sql = f"SELECT id, name, email FROM users WHERE name LIKE '%{query}%'"
    cursor.execute(sql)
    rows = cursor.fetchall()
    return {"users": [{"id": r[0], "name": r[1], "email": r[2]} for r in rows]}
```

Detection signal from `security-patterns-code-review`: **Injection (SQL)** — string concatenation in query, user input flows directly to `execute()`. Red flag: f-string interpolation inside SQL with `request.args` as source.

#### Step 2: Calibrate

Using `review-accuracy-calibration`:

- **Confidence: C4 — Certain.** Evidence is direct: `request.args.get("q")` → f-string → `cursor.execute()`. No indirection, no sanitization. A payload of `'; DROP TABLE users; --` executes immediately.
- **Severity: CRITICAL.** SQL injection allows arbitrary data read, data destruction, and potential RCE depending on database privileges.
- **False positive check:** Could there be sanitization upstream (middleware)? No Flask middleware shown. Even if there were, parameterized queries are the correct fix regardless.

#### Step 3: Write Feedback

Template from `review-feedback-quality` CRITICAL block:

```
[CRITICAL] SQL Injection in /users/search

What: User input from `request.args.get("q")` is interpolated directly
into a SQL string and executed without parameterization.

Why: An attacker can pass `'; DROP TABLE users; --` or
`' UNION SELECT password, null, null FROM admin_accounts --` as the
`q` parameter. No authentication is required. This is a confirmed
SQL injection (CWE-89) — not a theoretical risk.

Fix: Use parameterized queries. Replace the f-string SQL with a
placeholder and pass the value as a parameter tuple:

    sql = "SELECT id, name, email FROM users WHERE name LIKE %s"
    cursor.execute(sql, (f"%{query}%",))

Ref: OWASP SQL Injection, CWE-89, `security-patterns-code-review`
```

#### Step 4: After (Fixed Code)

```python
# After: parameterized query
@app.route("/users/search")
def search_users():
    query = request.args.get("q", "")
    cursor = conn.cursor()
    sql = "SELECT id, name, email FROM users WHERE name LIKE %s"
    cursor.execute(sql, (f"%{query}%",))
    rows = cursor.fetchall()
    return {"users": [{"id": r[0], "name": r[1], "email": r[2]} for r in rows]}
```

**Verdict: Request Changes — blocking.** SQL injection is a zero-tolerance finding. PR cannot merge until parameterized queries are used. No exceptions for "internal only" or "low traffic" arguments — the severity is data breach.

### Scenario 2: Performance Issue in Go Service

**Context:** A PR adds a product listing endpoint to a Go HTTP service. The handler fetches products and then loads the associated vendor for each product in a loop.

**Skills loaded:** `go-review-patterns`, `performance-anti-patterns`, `review-accuracy-calibration`, `review-feedback-quality`

#### Step 1: Detect

Reading the handler — a loop calls `getVendor(p.VendorID)` once per product. This is the N+1 query pattern.

```go
// Before: N+1 query pattern
func (h *ProductHandler) ListProducts(w http.ResponseWriter, r *http.Request) {
    products, err := h.db.QueryProducts()
    if err != nil {
        http.Error(w, "failed to fetch products", http.StatusInternalServerError)
        return
    }

    type ProductWithVendor struct {
        Product
        VendorName string `json:"vendor_name"`
    }

    result := make([]ProductWithVendor, 0, len(products))
    for _, p := range products {
        // N+1: one query per product
        vendor, err := h.db.GetVendor(p.VendorID)
        if err != nil {
            http.Error(w, "failed to fetch vendor", http.StatusInternalServerError)
            return
        }
        result = append(result, ProductWithVendor{Product: p, VendorName: vendor.Name})
    }

    json.NewEncoder(w).Encode(result)
}
```

Detection signal from `performance-anti-patterns`: **N+1 Query** — database call inside a loop iterating over a result set. With 500 products, this issues 501 queries per request. From `go-review-patterns`: no query batching, no JOIN, no context propagation to the database calls.

#### Step 2: Calibrate

Using `review-accuracy-calibration`:

- **Confidence: C3 — High.** The pattern is unambiguous: loop over products, query inside loop for each `VendorID`. The only scenario where this is acceptable is if `GetVendor` is a cache-only read with sub-microsecond latency, but no cache is evident in the code.
- **Severity: HIGH.** At scale this is a latency and database load issue. At 500 products: 501 queries. At 5000 products: 5001 queries. This degrades under load and can exhaust database connection pools.
- **False positive check:** Is `GetVendor` cached? No evidence. Is the product list always small (e.g., admin panel with 10 items)? No pagination shown, no size constraint.

#### Step 3: Write Feedback

```
[HIGH] N+1 Query: GetVendor called inside product loop

What: `h.db.GetVendor(p.VendorID)` is called once per product inside
the loop. For N products, this issues N+1 database queries per request.

Why: With 500 products this makes 501 queries. Under concurrent load
this saturates the connection pool, increases p99 latency significantly,
and adds unnecessary load to the database. N+1 is consistently among
the top performance regressions in service-to-database layers.

Fix: Collect all VendorIDs from the product slice, fetch them in a
single batch query, then join in memory:

    vendorIDs := collectVendorIDs(products)          // extract IDs
    vendors, err := h.db.GetVendorsByIDs(vendorIDs)  // one query
    vendorMap := indexByID(vendors)                   // map[ID]Vendor
    // then enrich products from the map

Ref: `performance-anti-patterns`, `go-review-patterns`
```

#### Step 4: After (Fixed Code)

```go
// After: batch fetch + in-memory join
func (h *ProductHandler) ListProducts(w http.ResponseWriter, r *http.Request) {
    products, err := h.db.QueryProducts()
    if err != nil {
        http.Error(w, "failed to fetch products", http.StatusInternalServerError)
        return
    }

    vendorIDs := make([]int64, 0, len(products))
    for _, p := range products {
        vendorIDs = append(vendorIDs, p.VendorID)
    }

    vendors, err := h.db.GetVendorsByIDs(vendorIDs) // single query
    if err != nil {
        http.Error(w, "failed to fetch vendors", http.StatusInternalServerError)
        return
    }

    vendorMap := make(map[int64]Vendor, len(vendors))
    for _, v := range vendors {
        vendorMap[v.ID] = v
    }

    type ProductWithVendor struct {
        Product
        VendorName string `json:"vendor_name"`
    }
    result := make([]ProductWithVendor, 0, len(products))
    for _, p := range products {
        result = append(result, ProductWithVendor{Product: p, VendorName: vendorMap[p.VendorID].Name})
    }

    json.NewEncoder(w).Encode(result)
}
```

**Verdict: Request Changes.** HIGH severity performance issue that will degrade under production load. The fix is well-defined and low risk. Suggest the author add a benchmark test to quantify the improvement.

### Scenario 3: AI-Generated TypeScript React Component

**Context:** A PR adds a `<UserCard>` component. The author used an LLM to generate it. The code compiles but has three issues: a hallucinated API method, a stale closure bug, and missing error handling.

**Skills loaded:** `ai-generated-code-review`, `typescript-review-patterns`, `review-accuracy-calibration`, `review-feedback-quality`

#### Step 1: Detect

Scanning the component with the AI-generated code checklist from `ai-generated-code-review`: hallucinated APIs, stale closures, missing error boundaries.

```typescript
// Before: AI-generated component with three defects
import React, { useState, useEffect } from "react";

interface User {
  id: string;
  name: string;
  email: string;
}

interface UserCardProps {
  userId: string;
  onRefresh: () => void;
}

export function UserCard({ userId, onRefresh }: UserCardProps) {
  const [user, setUser] = useState<User | null>(null);
  const [count, setCount] = useState(0);

  useEffect(() => {
    // DEFECT 1: React.fetchComponent does not exist — hallucinated API
    React.fetchComponent(`/api/users/${userId}`)
      .then((data: User) => setUser(data));
  }, [userId]);

  const handleRefresh = () => {
    // DEFECT 2: stale closure — count always reads initial value (0)
    // because handleRefresh is not in the dependency array
    console.log(`Refreshed ${count} times before`);
    setCount(count + 1);
    onRefresh();
  };

  // DEFECT 3: no loading state, no error handling, silent failure on fetch
  return (
    <div>
      <p>{user?.name}</p>
      <p>{user?.email}</p>
      <button onClick={handleRefresh}>Refresh</button>
    </div>
  );
}
```

Detection signals:

- `ai-generated-code-review`: hallucinated API — `React.fetchComponent` is not a real React API. The LLM invented it.
- `typescript-review-patterns`: stale closure — `count` inside `handleRefresh` is captured at definition time; `setCount(count + 1)` should use the functional update form.
- `review-efficiency-patterns`: no loading state, no error handling — fetch failures are silent; users see a blank card.

#### Step 2: Calibrate

Using `review-accuracy-calibration`:

- **Defect 1 (Hallucinated API) — C4 Certain, CRITICAL.** `React.fetchComponent` does not exist. This is a compile error / runtime crash. There is no ambiguity.
- **Defect 2 (Stale Closure) — C3 High, HIGH.** The `count` variable in `handleRefresh` will always read `0` because `handleRefresh` is recreated once on mount and closes over the initial value. This is a well-known React pattern bug.
- **Defect 3 (Missing Error Handling) — C3 High, HIGH.** The fetch promise has no `.catch()`. A network error or 404 silently leaves `user` as `null` with no user feedback. Standard quality bar for production components.

#### Step 3: Write Feedback

```
[CRITICAL] React.fetchComponent does not exist — AI hallucination

What: `React.fetchComponent` is not part of the React API. This call
will throw a TypeError at runtime: "React.fetchComponent is not a function".

Why: This appears to be an LLM hallucination — the model invented a
plausible-sounding method. The component will crash on mount for every user.

Fix: Use the Fetch API or the project's existing data-fetching utility:

    useEffect(() => {
      fetch(`/api/users/${userId}`)
        .then(res => res.json())
        .then((data: User) => setUser(data))
        .catch(err => setError(err.message));
    }, [userId]);

Ref: React docs — useEffect data fetching, `ai-generated-code-review`


[HIGH] Stale closure: count reads initial value in handleRefresh

What: `handleRefresh` captures `count` at its creation time (0). Each
subsequent click increments from the stale snapshot, not the current value.

Why: In React, state values inside closures become stale when the
closure is not recreated with updated dependencies. `console.log` will
always print 0, and `setCount(count + 1)` will reset to 1 on every click.

Fix: Use the functional update form to read current state:

    setCount(prev => prev + 1);

Ref: React docs — functional updates, `typescript-review-patterns`


[HIGH] No error handling or loading state

What: The fetch has no `.catch()`, and there is no loading indicator.
Failed requests leave the component silently blank.

Why: Users see an empty card with no explanation. Errors are invisible
to both the user and to logging/monitoring. This is below the project's
minimum quality bar for data-fetching components.

Fix: Add error and loading state. See the project's existing
`<DataCard>` component for the standard loading/error pattern.

Ref: `review-feedback-quality`, `ai-generated-code-review`
```

#### Step 4: After (Fixed Code)

```typescript
// After: corrected component
import React, { useState, useEffect, useCallback } from "react";

interface User { id: string; name: string; email: string; }
interface UserCardProps { userId: string; onRefresh: () => void; }

export function UserCard({ userId, onRefresh }: UserCardProps) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [count, setCount] = useState(0);

  useEffect(() => {
    setLoading(true);
    setError(null);
    fetch(`/api/users/${userId}`)
      .then(res => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json() as Promise<User>;
      })
      .then(data => setUser(data))
      .catch(err => setError(err.message))
      .finally(() => setLoading(false));
  }, [userId]);

  const handleRefresh = useCallback(() => {
    setCount(prev => prev + 1); // functional update — no stale closure
    onRefresh();
  }, [onRefresh]);

  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error}</div>;
  if (!user) return null;

  return (
    <div>
      <p>{user.name}</p>
      <p>{user.email}</p>
      <button onClick={handleRefresh}>Refresh</button>
    </div>
  );
}
```

**Verdict: Request Changes.** Three HIGH/CRITICAL issues including a runtime crash. The component cannot ship as written. Tip for the author: when using LLM-generated code, cross-check all API calls against the official documentation before submitting.

### Scenario 4: Java Concurrency Bug

**Context:** A PR adds a `RequestCounterService` to a Spring Boot service. Multiple threads increment and read a shared counter without synchronization.

**Skills loaded:** `java-review-patterns`, `concurrency-patterns`, `review-accuracy-calibration`, `review-feedback-quality`

#### Step 1: Detect

Scanning for shared mutable state accessed from multiple threads. `requestCount` is a plain `int` field modified by `increment()` and read by `getCount()`. No synchronization, no volatile, no atomic type.

```java
// Before: unsynchronized shared state
import org.springframework.stereotype.Service;

@Service
public class RequestCounterService {

    // DEFECT: plain int — not thread-safe
    private int requestCount = 0;

    public void increment() {
        requestCount++;  // read-modify-write: not atomic
    }

    public int getCount() {
        return requestCount;  // may read stale value
    }

    public void reset() {
        requestCount = 0;
    }
}
```

Detection signals from `java-review-patterns` + `concurrency-patterns`:

- `requestCount++` is not atomic: it compiles to read, increment, write — three separate operations. Two threads can interleave and lose increments.
- Spring `@Service` beans are singletons by default — this single instance is shared across all request threads in the thread pool.
- No `volatile` keyword means the JVM may cache `requestCount` in a CPU register, so `getCount()` can return a stale value even if `increment()` ran on another thread.

#### Step 2: Calibrate

Using `review-accuracy-calibration`:

- **Confidence: C4 — Certain.** Evidence is direct: `@Service` singleton, plain `int`, `requestCount++`. This is a textbook data race. There is no scenario in a Spring Boot service where this is safe.
- **Severity: CRITICAL.** Data races cause lost increments (incorrect metrics), stale reads, and — depending on JVM and hardware — can cause visibility issues that corrupt other fields in the same object. This is a reliability defect that worsens under load.
- **False positive check:** Could this be single-threaded? Spring Boot uses a thread-per-request model by default; concurrent requests are guaranteed in any real-world deployment.

#### Step 3: Write Feedback

```
[CRITICAL] Data race on requestCount — unsynchronized shared mutable state

What: `requestCount` is a plain `int` field on a `@Service` singleton.
`requestCount++` is a non-atomic read-modify-write sequence. Multiple
request-handling threads will race on this field.

Why: Spring @Service beans are singletons — this single instance is
shared across all threads in the server's thread pool. Under concurrent
load:
  - Increments will be lost (thread A reads 5, thread B reads 5, both
    write 6 — net effect: +1 instead of +2).
  - `getCount()` may return a cached value due to CPU register
    optimization — the JVM does not guarantee cross-thread visibility
    for non-volatile fields.
  - `reset()` has the same visibility problem.

This is a confirmed data race (CWE-362). The counter will produce
incorrect values in production.

Fix: Replace `int` with `AtomicInteger`:

    import java.util.concurrent.atomic.AtomicInteger;

    private final AtomicInteger requestCount = new AtomicInteger(0);

    public void increment() { requestCount.incrementAndGet(); }
    public int getCount()   { return requestCount.get(); }
    public void reset()     { requestCount.set(0); }

AtomicInteger uses compare-and-swap (CAS) CPU instructions — no locks,
no synchronized blocks, no performance overhead for this use case.

Ref: Java concurrency docs, CWE-362, `java-review-patterns`, `concurrency-patterns`
```

#### Step 4: After (Fixed Code)

```java
// After: thread-safe with AtomicInteger
import org.springframework.stereotype.Service;
import java.util.concurrent.atomic.AtomicInteger;

@Service
public class RequestCounterService {

    private final AtomicInteger requestCount = new AtomicInteger(0);

    public void increment() {
        requestCount.incrementAndGet();
    }

    public int getCount() {
        return requestCount.get();
    }

    public void reset() {
        requestCount.set(0);
    }
}
```

**Verdict: Request Changes — blocking.** Concurrent data races are correctness bugs, not style issues. The PR cannot merge. This is a single-line type change with no API impact. The fix should take under five minutes; flag it as such in the comment so the author does not feel blocked by a large rework.

## Quick Reference — Full Flow

| Step | Action | Skill |
|------|--------|-------|
| 1 — Detect | Match code patterns to known vulnerability / anti-pattern | `security-patterns-code-review`, `go-review-patterns`, `performance-anti-patterns`, `ai-generated-code-review`, `typescript-review-patterns`, `java-review-patterns`, `concurrency-patterns` |
| 2 — Calibrate | Assign C1–C4 confidence, assign severity, check false positives | `review-accuracy-calibration` |
| 3 — Write | Apply CRITICAL / HIGH / MEDIUM / NIT template | `review-feedback-quality` |
| 4 — Decide | Block (CRITICAL/HIGH), suggest (MEDIUM), nit (NIT), approve | `review-workflow`, `review-efficiency-patterns` |

## Cross-References

| Topic | Skill |
|-------|-------|
| Full review workflow end-to-end | `review-workflow` |
| Severity calibration and false positive reduction | `review-accuracy-calibration` |
| Comment templates and tone | `review-feedback-quality` |
| Time allocation and stopping signals | `review-efficiency-patterns` |
| SQL injection, XSS, auth, secrets | `security-patterns-code-review` |
| Go idioms, error handling, goroutine safety | `go-review-patterns` |
| N+1 queries, cache misuse, hot loops | `performance-anti-patterns` |
| LLM hallucinations, stale closures, missing error handling | `ai-generated-code-review` |
| React hooks, TypeScript types, strict null | `typescript-review-patterns` |
| Java concurrency, synchronized, volatile, AtomicInteger | `java-review-patterns` |
| Thread safety, data races, deadlock detection | `concurrency-patterns` |
