---
name: security-patterns-code-review
description: Use when reviewing code for security vulnerabilities — covers Injection, Broken Authentication, Sensitive Data Exposure, XXE, Broken Access Control, Security Misconfiguration, XSS, Insecure Deserialization, Vulnerable Components, Insufficient Logging, Secret Management, CSRF, Rate Limiting, and Input Validation with red flags and fix strategies across TypeScript, Python, Java, and Go
---

# Security Patterns for Code Review

## Overview

Security vulnerabilities are cheapest to fix at code review. SQL injection, hardcoded secrets, and missing authorization checks all have clear code-level signatures. Use this guide during PR review to catch OWASP Top 10 risks before they ship.

**When to use:** Reviewing PRs that touch authentication, data access, user input handling, external API calls, or configuration.

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

**Description:** Untrusted data sent to an interpreter as part of a command or query.

**Code Review Red Flags:**
- String concatenation to build SQL: `"SELECT * FROM users WHERE id = " + userId`
- `exec`, `execSync`, `subprocess.call(shell=True)` with any user-controlled value
- ORM raw query fallback with unparameterized input: `db.raw(query + input)`

**TypeScript — Before/After:**
```typescript
// BEFORE — SQL injection: attacker sends "1 OR 1=1"
const rows = await db.query(`SELECT * FROM orders WHERE user_id = '${req.params.id}'`);

// AFTER — parameterized query; driver handles escaping
const rows = await db.query('SELECT * FROM orders WHERE user_id = $1', [req.params.id]);
```

**Python — command injection:** `subprocess.call(f"process {filename}", shell=True)` → `subprocess.run(["process", filename], check=True)` — list form bypasses shell interpretation.

---

### 2. Broken Authentication

**Description:** Weak auth mechanisms allow attackers to compromise passwords, tokens, or impersonate users.

**Code Review Red Flags:**
- Passwords stored with MD5/SHA-1 — not bcrypt/argon2
- Hardcoded credentials: `const API_KEY = "sk-live-abc123"`
- JWT without `exp` claim or without signature verification
- Session IDs not rotated after login (session fixation)

**TypeScript — Before/After:**
```typescript
// BEFORE — MD5 hash, trivially reversible
const hash = crypto.createHash('md5').update(password).digest('hex');

// AFTER — bcrypt with work factor 12
import bcrypt from 'bcrypt';
const hash = await bcrypt.hash(password, 12);
```

**Go — JWT validation:**
```go
// BEFORE: jwt.ParseWithClaims(tokenStr, &Claims{}, nil) — no signature check

// AFTER — require valid signature and expiry
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

**Description:** PII, credentials, or financial data exposed through logs, APIs, or weak encryption.

**Code Review Red Flags:**
- `logger.info('User logged in', { user })` — object may contain password hash or PII
- HTTP (not HTTPS) URLs in API client config
- `JSON.stringify(error)` in API responses that may leak stack traces

```typescript
// BEFORE: logger.info('User logged in', { user }); — logs password hash and PII
// AFTER — log only non-sensitive identifiers
logger.info('User logged in', { userId: user.id, email: maskEmail(user.email) });
```

---

### 4. XML External Entities (XXE)

**Description:** XML parsers that process external entities allow attackers to read local files or perform SSRF.

**Code Review Red Flags:**
- `DocumentBuilderFactory`, `SAXParserFactory` without disabling DTD
- Accepting XML from user input without entity processing disabled

**Java — After:**
```java
DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
factory.setFeature("http://xml.org/sax/features/external-general-entities", false);
```

**Python:** replace `xml.etree.ElementTree` with `defusedxml.ElementTree` — blocks XXE and billion-laughs attacks.

---

### 5. Broken Access Control

**Description:** Authentication present but authorization missing — users access other users' data or escalate privileges.

**Code Review Red Flags:**
- Route queries by user-supplied ID without verifying ownership (IDOR)
- Missing auth middleware on protected routes
- Role checks only on the frontend, not enforced server-side

**TypeScript — Before/After:**
```typescript
// BEFORE — IDOR: any authenticated user can read any order
app.get('/orders/:id', authenticate, async (req, res) => {
  const order = await orderRepo.findById(req.params.id);
  res.json(order);
});

// AFTER — verify caller owns the resource
app.get('/orders/:id', authenticate, async (req, res) => {
  const order = await orderRepo.findById(req.params.id);
  if (!order || order.userId !== req.user.id) return res.status(403).json({ error: 'Forbidden' });
  res.json(order);
});
```

**Go — role middleware:**
```go
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

**Description:** Insecure defaults, debug mode in production, permissive CORS, or missing security headers.

**Code Review Red Flags:**
- `cors({ origin: '*' })` on authenticated endpoints
- Missing `helmet()` or equivalent security headers middleware
- Stack traces returned in production error responses

**TypeScript — Before/After:**
```typescript
// BEFORE — wide-open CORS, no security headers
app.use(cors());

// AFTER — scoped CORS, helmet headers, hide server fingerprint
import helmet from 'helmet';
const allowed = (process.env.ALLOWED_ORIGINS ?? '').split(',');
app.use(helmet());
app.use(cors({ origin: (o, cb) => allowed.includes(o ?? '') ? cb(null, true) : cb(new Error('CORS')) }));
app.disable('x-powered-by');
```

---

### 7. Cross-Site Scripting (XSS)

**Description:** Attacker injects client-side scripts via stored or reflected user content.

**Code Review Red Flags:**
- `element.innerHTML = userInput` — executes embedded `<script>` tags
- React `dangerouslySetInnerHTML={{ __html: userContent }}` without sanitization
- Missing Content-Security-Policy header

**TypeScript — Before/After:**
```typescript
// BEFORE — stored XSS: comment body contains <script>document.cookie</script>
element.innerHTML = comment.body;

// AFTER — DOMPurify strips executable content
import DOMPurify from 'dompurify';
element.innerHTML = DOMPurify.sanitize(comment.body, { ALLOWED_TAGS: ['b', 'i', 'em', 'p'] });
```

---

### 8. Insecure Deserialization

**Description:** Deserializing attacker-controlled data can trigger remote code execution when object graphs are reconstructed without validation.

**Code Review Red Flags:**
- `pickle.loads(data)` on network or user-supplied input
- Java `ObjectInputStream` reading from a socket or upload
- `yaml.load()` (unsafe) instead of `yaml.safe_load()`

**Python — Before/After:**
```python
# BEFORE — pickle executes arbitrary code on load
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

### 9. Using Components with Known Vulnerabilities

**Description:** Outdated libraries with published CVEs extend the attack surface without writing a single vulnerable line.

**Code Review Red Flags:**
- No `package-lock.json` or `yarn.lock` — non-deterministic installs
- `"*"` or `"latest"` version ranges in dependency files
- No `npm audit` / `pip-audit` / `govulncheck` step in CI

**Fix Strategy:** add to CI before deploy:
```bash
npm audit --audit-level=high   # Node.js
pip-audit                      # Python
govulncheck ./...              # Go
```

---

### 10. Insufficient Logging and Monitoring

**Description:** Without audit trails for auth events, breaches go undetected and forensics are impossible.

**Code Review Red Flags:**
- No logging on failed login attempts — brute force invisible
- `catch (err) {}` — errors silently swallowed, no alert triggered
- Log entries missing correlation IDs — cross-service tracing impossible

**TypeScript — Before/After:**
```typescript
// BEFORE — no audit trail
app.post('/login', async (req, res) => {
  const user = await authService.login(req.body.email, req.body.password);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });
  res.json({ token: issueToken(user) });
});

// AFTER — structured audit log for every auth outcome
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

**Description:** API keys or passwords embedded in source are exposed to all repo contributors and persist in git history.

**Code Review Red Flags:**
- `const DB_PASSWORD = "supersecret"` anywhere in source
- `.env` file committed (not in `.gitignore`)
- Secrets in Dockerfile `ARG` instructions

**TypeScript — Before/After:**
```typescript
// BEFORE: const stripe = new Stripe("sk_live_abc123xyz");

// AFTER — read from env; fail fast if missing
const stripeKey = process.env.STRIPE_SECRET_KEY;
if (!stripeKey) throw new Error('STRIPE_SECRET_KEY is required');
const stripe = new Stripe(stripeKey);
```

---

### 12. CSRF Protection

**Description:** Forged requests from malicious sites use the victim's authenticated session to perform unintended state changes.

**Code Review Red Flags:**
- `GET` endpoints that perform state changes (delete, transfer)
- Missing CSRF middleware on form-based backends
- `SameSite=None` cookies without `Secure` flag

**TypeScript — After:**
```typescript
import csurf from 'csurf';
const csrf = csurf({ cookie: { httpOnly: true, sameSite: 'strict' } });
app.post('/transfer', authenticate, csrf, transferFunds);
// Form: <input type="hidden" name="_csrf" value="<%= csrfToken %>">
```

---

### 13. Rate Limiting

**Description:** Unbounded API access enables credential brute-force, data scraping, or denial of service.

**Code Review Red Flags:**
- Login, registration, and password-reset endpoints with no rate limit
- Rate limiting only at the load balancer but not enforced per-user

**TypeScript — After (10 attempts per IP per 15 minutes):**
```typescript
import rateLimit from 'express-rate-limit';
const loginLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 10, standardHeaders: true });
app.post('/login', loginLimiter, loginHandler);
```

---

### 14. Input Validation

**Description:** Trusting unvalidated external data allows malformed input to corrupt business logic or reach injection sinks.

**Code Review Red Flags:**
- Validation only on the frontend; server accepts any payload shape
- Numeric fields unbounded: `qty: number` instead of `min(1).max(1000)`
- No length caps on free-text fields — open to DoS via large payloads

**TypeScript — Before/After:**
```typescript
// BEFORE — trusts req.body shape; no type or range check
app.post('/orders', authenticate, async (req, res) => {
  res.json(await orderService.create(req.body));
});

// AFTER — Zod enforces shape, types, and ranges at the boundary
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

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Security by Obscurity** | Hiding endpoint paths instead of enforcing auth | Enforce authentication regardless of URL shape |
| **Client-Side Auth** | Authorization checks only in JavaScript/UI | All access control decisions made server-side |
| **Regex as Security** | Regex alone to prevent injection | Parameterized queries and encoding are the fix; regex supplements |
| **Trust the Referer** | Validating origin via `Referer` header | Headers are attacker-controlled; use CSRF tokens or SameSite cookies |
| **Boolean `isAdmin` in JWT** | Trusting role claims from client-supplied token | Load roles from the database on each request, not from the token |
| **Catch-and-Log-Secrets** | Exception message includes SQL with credentials | Sanitize error messages before logging; never log raw query params |
| **Permissive Deserialize** | `JSON.parse(input)` drives business logic without schema | Validate deserialized data against a strict schema before use |
| **HTTP for Internal APIs** | Internal service calls over plain HTTP | Use mutual TLS or HTTPS even for internal traffic |

---

## Cross-References

- `review-code-quality-process` — embed this skill's red flags in the PR checklist; security review before any "LGTM"
- `error-handling-patterns` — catch-and-swallow errors (Pokemon Exception Handling) are the direct cause of Insufficient Logging (area 10)
- `review-solid-clean-code` — authorization logic scattered across handlers (not centralized in middleware) is a Broken Access Control signal
- `anti-patterns-catalog` — God Object applied to auth: monolithic auth modules with unclear boundaries are harder to audit for privilege escalation
