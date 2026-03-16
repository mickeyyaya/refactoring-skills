---
name: security-patterns-code-review
description: Use when reviewing code for security vulnerabilities — covers Injection, Broken Authentication, Sensitive Data Exposure, XXE, Broken Access Control, Security Misconfiguration, XSS, Insecure Deserialization, Vulnerable Components, Insufficient Logging, Secret Management, CSRF, Rate Limiting, and Input Validation with red flags and fix strategies across TypeScript, Python, Java, and Go
---

# Security Patterns for Code Review

## Overview

Security vulnerabilities are cheapest to fix at code review. Use this guide during PR review to catch OWASP Top 10 risks before they ship.

**When to use:** PRs touching authentication, data access, user input, external APIs, or configuration.

## Quick Reference

| Area | Severity | Primary Red Flag |
|------|----------|-----------------|
| Injection (SQL/Command/LDAP) | Critical | String concatenation in queries, `exec`/`eval` with user input |
| Broken Authentication | Critical | Plaintext passwords, hardcoded secrets, JWT without expiry |
| Sensitive Data Exposure | High | Logging PII, HTTP endpoints, secrets in source code |
| XML External Entities | High | XML parsing without DTD disabled |
| Broken Access Control | Critical | Missing auth middleware, IDOR, role check gaps |
| Security Misconfiguration | High | Debug in production, permissive CORS, missing headers |
| Cross-Site Scripting | High | `innerHTML` with user data, `dangerouslySetInnerHTML` |
| Insecure Deserialization | High | `pickle.loads`, `ObjectInputStream`, unvalidated `JSON.parse` |
| Vulnerable Components | Medium | Outdated packages, no lockfile, no `audit` in CI |
| Insufficient Logging | Medium | No auth event logging, swallowed errors |
| Secret Management | Critical | API keys in source, `.env` committed to git |
| CSRF Protection | High | State-changing GET requests, missing CSRF middleware |
| Rate Limiting | Medium | No throttle on auth endpoints |
| Input Validation | High | Regex-only validation, trusting client-side checks |

---

## Patterns in Detail

### 1. Injection (SQL, NoSQL, Command, LDAP)

**Red Flags:** String concatenation in SQL; `exec`/`subprocess.call(shell=True)` with user values; ORM raw queries unparameterized.

```typescript
// BEFORE — SQL injection: attacker sends "1 OR 1=1"
const rows = await db.query(`SELECT * FROM orders WHERE user_id = '${req.params.id}'`);

// AFTER — parameterized query
const rows = await db.query('SELECT * FROM orders WHERE user_id = $1', [req.params.id]);
```

**Python:** `subprocess.call(f"process {filename}", shell=True)` → `subprocess.run(["process", filename], check=True)` — list form bypasses shell.

---

### 2. Broken Authentication

**Red Flags:** MD5/SHA-1 passwords; hardcoded credentials; JWT without `exp` or signature verification; session IDs not rotated.

```typescript
// BEFORE — MD5, trivially reversible
const hash = crypto.createHash('md5').update(password).digest('hex');

// AFTER — bcrypt with work factor 12
import bcrypt from 'bcrypt';
const hash = await bcrypt.hash(password, 12);
```

```go
// Go — JWT: require valid signature and expiry
token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
    if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
        return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
    }
    return []byte(os.Getenv("JWT_SECRET")), nil
})
if err != nil || !token.Valid { return nil, ErrUnauthorized }
```

---

### 3. Sensitive Data Exposure

**Red Flags:** Logging full user objects (PII); HTTP URLs in API config; `JSON.stringify(error)` leaking stack traces.

```typescript
// BEFORE: logger.info('User logged in', { user }); — logs PII
// AFTER — log only non-sensitive identifiers
logger.info('User logged in', { userId: user.id, email: maskEmail(user.email) });
```

---

### 4. XML External Entities (XXE)

**Red Flags:** XML parser factories without DTD disabled; user XML without entity processing disabled.

```java
// Java — disable DTD and external entities
DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
```

**Python:** replace `xml.etree.ElementTree` with `defusedxml.ElementTree`.

---

### 5. Broken Access Control

**Red Flags:** IDOR (query by user-supplied ID without ownership check); missing auth middleware; frontend-only role checks.

```typescript
// BEFORE — IDOR: any authenticated user reads any order
app.get('/orders/:id', authenticate, async (req, res) => {
  const order = await orderRepo.findById(req.params.id);
  res.json(order);
});

// AFTER — verify ownership
app.get('/orders/:id', authenticate, async (req, res) => {
  const order = await orderRepo.findById(req.params.id);
  if (!order || order.userId !== req.user.id) return res.status(403).json({ error: 'Forbidden' });
  res.json(order);
});
```

```go
// Go — role middleware
func RequireRole(role string) gin.HandlerFunc {
    return func(c *gin.Context) {
        user := c.MustGet("user").(User)
        if !slices.Contains(user.Roles, role) {
            c.AbortWithStatusJSON(403, gin.H{"error": "forbidden"}); return
        }
        c.Next()
    }
}
```

---

### 6. Security Misconfiguration

**Red Flags:** `cors({ origin: '*' })` on auth endpoints; missing security headers; stack traces in production.

```typescript
// BEFORE — wide-open CORS, no security headers
app.use(cors());

// AFTER — scoped CORS, helmet, hide fingerprint
import helmet from 'helmet';
const allowed = (process.env.ALLOWED_ORIGINS ?? '').split(',');
app.use(helmet());
app.use(cors({ origin: (o, cb) => allowed.includes(o ?? '') ? cb(null, true) : cb(new Error('CORS')) }));
app.disable('x-powered-by');
```

---

### 7. Cross-Site Scripting (XSS)

**Red Flags:** `innerHTML = userInput`; `dangerouslySetInnerHTML` without sanitization; missing CSP header.

```typescript
// BEFORE — stored XSS
element.innerHTML = comment.body;

// AFTER — DOMPurify strips executable content
import DOMPurify from 'dompurify';
element.innerHTML = DOMPurify.sanitize(comment.body, { ALLOWED_TAGS: ['b', 'i', 'em', 'p'] });
```

---

### 8. Insecure Deserialization

**Red Flags:** `pickle.loads` on user input; `ObjectInputStream` from socket/upload; `yaml.load()` vs `yaml.safe_load()`.

```python
# BEFORE — pickle executes arbitrary code
import pickle
obj = pickle.loads(request.data)

# AFTER — JSON + Pydantic schema validation
from pydantic import BaseModel
class TaskPayload(BaseModel):
    task_id: str
    priority: int
payload = TaskPayload.model_validate_json(request.data)
```

---

### 9. Vulnerable Components

**Red Flags:** No lockfile; `"*"`/`"latest"` version ranges; no audit step in CI.

**Fix:** add to CI:
```bash
npm audit --audit-level=high   # Node.js
pip-audit                      # Python
govulncheck ./...              # Go
```

---

### 10. Insufficient Logging

**Red Flags:** No logging on failed logins; `catch (err) {}` swallowing errors; missing correlation IDs.

```typescript
// BEFORE — no audit trail
app.post('/login', async (req, res) => {
  const user = await authService.login(req.body.email, req.body.password);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });
  res.json({ token: issueToken(user) });
});

// AFTER — structured audit log
app.post('/login', async (req, res) => {
  const { email, password } = req.body;
  const user = await authService.login(email, password);
  if (!user) {
    logger.warn('auth.login.failed', { email, ip: req.ip });
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  logger.info('auth.login.success', { userId: user.id, ip: req.ip });
  res.json({ token: issueToken(user) });
});
```

---

### 11. Secret Management

**Red Flags:** Hardcoded passwords in source; `.env` committed; secrets in Dockerfile `ARG`.

```typescript
// BEFORE: const stripe = new Stripe("sk_live_abc123xyz");

// AFTER — read from env; fail fast if missing
const stripeKey = process.env.STRIPE_SECRET_KEY;
if (!stripeKey) throw new Error('STRIPE_SECRET_KEY is required');
const stripe = new Stripe(stripeKey);
```

---

### 12. CSRF Protection

**Red Flags:** State-changing `GET` endpoints; missing CSRF middleware; `SameSite=None` without `Secure`.

```typescript
import csurf from 'csurf';
const csrf = csurf({ cookie: { httpOnly: true, sameSite: 'strict' } });
app.post('/transfer', authenticate, csrf, transferFunds);
```

---

### 13. Rate Limiting

**Red Flags:** Auth endpoints without throttle; rate limiting only at load balancer, not per-user.

```typescript
import rateLimit from 'express-rate-limit';
const loginLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 10, standardHeaders: true });
app.post('/login', loginLimiter, loginHandler);
```

---

### 14. Input Validation

**Red Flags:** Frontend-only validation; unbounded numeric fields; no length caps on text fields.

```typescript
// BEFORE — trusts req.body shape
app.post('/orders', authenticate, async (req, res) => {
  res.json(await orderService.create(req.body));
});

// AFTER — Zod enforces shape, types, and ranges
const CreateOrderSchema = z.object({
  items: z.array(z.object({ sku: z.string().regex(/^[A-Z0-9-]{3,20}$/), qty: z.number().int().min(1).max(1000) })).min(1).max(50),
  shippingAddress: z.string().min(10).max(500),
});
app.post('/orders', authenticate, async (req, res) => {
  const result = CreateOrderSchema.safeParse(req.body);
  if (!result.success) return res.status(400).json({ errors: result.error.flatten() });
  res.json(await orderService.create(result.data));
});
```

---

## Security Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| **Security by Obscurity** — hiding URLs instead of auth | Enforce authentication regardless of URL |
| **Client-Side Auth** — checks only in UI | All access control server-side |
| **Regex as Security** — regex alone vs injection | Parameterized queries; regex supplements |
| **Trust the Referer** — origin via header | CSRF tokens or SameSite cookies |
| **Boolean `isAdmin` in JWT** — role claims from token | Load roles from DB each request |
| **Catch-and-Log-Secrets** — SQL in exceptions | Sanitize error messages before logging |
| **Permissive Deserialize** — `JSON.parse` without schema | Validate against strict schema first |
| **HTTP for Internal APIs** — plain HTTP internally | Mutual TLS or HTTPS even internally |

---

## Cross-References

- `review-code-quality-process` — embed red flags in PR checklist
- `error-handling-patterns` — catch-and-swallow causes Insufficient Logging (area 10)
- `review-solid-clean-code` — scattered auth logic signals Broken Access Control
- `anti-patterns-catalog` — monolithic auth modules harder to audit for privilege escalation
