---
name: ai-generated-code-review
description: Use when reviewing LLM/AI-generated code — covers hallucinated APIs, plausible-but-wrong logic, authorization gaps, shallow error handling, over-abstraction, copy-paste context mismatch, missing edge cases, and outdated patterns with detection strategies and before/after examples in TypeScript, Python, and Go
---

# AI-Generated Code Review

## Overview

AI-generated code fails differently than human-written code. A human who doesn't know an API will leave a TODO or look it up. An LLM will confidently invent a plausible-looking method that doesn't exist. A human writing access control will think about threat models. An LLM trained on tutorial code will skip auth entirely because tutorials rarely include it.

**The core problem:** LLM-generated code is syntactically fluent but semantically unreliable. It looks correct at a glance, passes linters, and often passes type checkers — yet silently does the wrong thing, calls methods that don't exist, or leaves security-critical paths unguarded.

**When to use this guide:** Any PR where a contributor used AI assistance, or where the code has the stylistic markers of AI output — unusually consistent formatting, generic variable names, verbose boilerplate, excessive comments explaining obvious things.

**Mindset shift:** Standard review asks "is this code correct?" AI code review asks "did the AI understand the actual requirements, or did it generate plausible code for a slightly different problem?"

## Quick Reference — AI Code Smell Severity

| Smell | Severity | Primary Signal |
|-------|----------|---------------|
| Hallucinated API | Critical | Method/package does not exist in the installed version |
| Missing authorization | Critical | No ownership or role check on resource access |
| Plausible-but-wrong logic | High | Code runs, wrong result — passes review but fails in prod |
| Shallow error handling | High | `catch (e) {}`, `except: pass`, swallowed errors |
| Copy-paste context mismatch | High | Code from wrong framework, version, or language idiom |
| Missing edge cases | Medium | Happy-path only — nil, empty, overflow, concurrent access |
| Over-abstraction | Medium | Factory/strategy/decorator for a 10-line function |
| Outdated patterns | Medium | Deprecated API, old library version idiom |

---

## AI Code Smells Catalog

### Smell 1: Hallucinated API Calls

The LLM invents method names that sound plausible given the object type but don't exist in the actual library. Common in: date/time libraries, ORMs, SDK clients, testing utilities.

**Signals:**
- Method names that read naturally but produce `TypeError`/`AttributeError` at runtime
- Chained calls on objects that don't support them
- Named parameters that the function signature doesn't define
- Package imports from libraries that don't exist on PyPI/npm/pkg.go.dev

```typescript
// BEFORE — hallucinated Prisma API (findManyWhere does not exist)
const activeUsers = await prisma.user.findManyWhere({
  status: 'active',
  lastLoginAfter: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000),
});

// AFTER — actual Prisma query API
const activeUsers = await prisma.user.findMany({
  where: {
    status: 'active',
    lastLoginAt: { gte: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000) },
  },
});
```

**Detection strategy:** Run the code. If you can't, search the official API docs or source for the exact method name. Don't trust that "it looks right."

---

### Smell 2: Plausible-but-Wrong Logic

The code runs without errors and produces output that looks reasonable — but the logic is subtly incorrect. LLMs frequently get: off-by-one errors in date arithmetic, inverted boolean conditions, wrong operator precedence, comparing by reference instead of value.

**Signals:**
- Business logic in a domain you know — does the math actually work?
- Date/time arithmetic without explicit timezone handling
- Comparison operations on complex objects
- Aggregation logic (sum, average, percentile) — verify the formula

```python
# BEFORE — off-by-one in pagination, wrong operator (skips last page)
def get_page_items(items: list, page: int, page_size: int) -> list:
    start = page * page_size
    end = start + page_size
    return items[start:end]  # page=0 returns items 0..9 correctly
                              # but caller passes page=1 for "first page"
                              # convention mismatch: 0-indexed vs 1-indexed

# AFTER — explicit convention, validated
def get_page_items(items: list, page: int, page_size: int) -> list:
    """Return items for 1-indexed page number."""
    if page < 1:
        raise ValueError(f"page must be >= 1, got {page}")
    start = (page - 1) * page_size
    end = start + page_size
    return items[start:end]
```

**Detection strategy:** Trace the logic with a concrete example. Don't read what you expect the code to do — trace what it actually does, step by step.

---

### Smell 3: Missing Authorization Checks

LLMs trained on tutorial code produce unauthenticated-by-default patterns. Authentication middleware often gets added, but authorization (does this user own this resource? do they have the right role?) is frequently absent.

**Signals:**
- Route fetches a resource by user-supplied ID without verifying ownership
- Admin operations protected only by UI routing, not server-side role checks
- Bulk operations that allow cross-tenant data access

```typescript
// BEFORE — authenticated but not authorized (any user reads any document)
router.get('/documents/:id', requireAuth, async (req, res) => {
  const doc = await documentRepo.findById(req.params.id);
  if (!doc) return res.status(404).json({ error: 'Not found' });
  res.json(doc);
});

// AFTER — ownership verified before returning data
router.get('/documents/:id', requireAuth, async (req, res) => {
  const doc = await documentRepo.findById(req.params.id);
  if (!doc) return res.status(404).json({ error: 'Not found' });
  if (doc.ownerId !== req.user.id && !req.user.roles.includes('admin')) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  res.json(doc);
});
```

See also: `security-patterns-code-review` pattern 5 (Broken Access Control).

---

### Smell 4: Shallow Error Handling

LLMs often generate the happy path with perfunctory catch blocks. The catch either swallows the error silently, re-throws without context, or logs a generic message that destroys the stack trace.

**Signals:**
- `catch (e) { console.log(e) }` or `except: pass`
- Catch block that catches `Exception` broadly then continues as if nothing happened
- Error message contains no actionable context (which operation, which input)
- No distinction between retryable and fatal errors

```go
// BEFORE — swallowed error, caller has no idea what failed
func fetchUserProfile(userID string) (*UserProfile, error) {
    resp, err := httpClient.Get(fmt.Sprintf("/users/%s", userID))
    if err != nil {
        log.Println("error fetching user")
        return nil, nil  // returns nil error — caller thinks it succeeded
    }
    defer resp.Body.Close()
    var profile UserProfile
    if err := json.NewDecoder(resp.Body).Decode(&profile); err != nil {
        return nil, nil  // decode failure also swallowed
    }
    return &profile, nil
}

// AFTER — errors wrapped with context, nil-nil eliminated
func fetchUserProfile(userID string) (*UserProfile, error) {
    resp, err := httpClient.Get(fmt.Sprintf("/users/%s", userID))
    if err != nil {
        return nil, fmt.Errorf("fetchUserProfile: HTTP GET for user %s: %w", userID, err)
    }
    defer resp.Body.Close()
    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("fetchUserProfile: unexpected status %d for user %s", resp.StatusCode, userID)
    }
    var profile UserProfile
    if err := json.NewDecoder(resp.Body).Decode(&profile); err != nil {
        return nil, fmt.Errorf("fetchUserProfile: decode response for user %s: %w", userID, err)
    }
    return &profile, nil
}
```

See also: `error-handling-patterns` for wrapping conventions.

---

### Smell 5: Over-Abstraction

LLMs default to "enterprise" patterns — factories, strategy objects, dependency injection containers — even when the code has one caller, one use case, and will never need extension. This adds indirection that increases cognitive load without adding value.

**Signals:**
- Interface defined and immediately implemented by a single concrete type, never tested via the interface
- Factory function with a single `type` parameter and a single case in the switch
- Abstract base class hierarchy three levels deep for a utility function
- "Handler" or "Processor" class with only one method that wraps a 5-line operation

**Red flag example (TypeScript):**
```typescript
// AI-generated over-abstraction for a simple email send
interface NotificationStrategy {
  send(recipient: string, subject: string, body: string): Promise<void>;
}
class EmailNotificationStrategy implements NotificationStrategy { ... }
class NotificationStrategyFactory {
  static create(type: 'email'): NotificationStrategy { ... }
}
const factory = new NotificationStrategyFactory();
const strategy = NotificationStrategyFactory.create('email');
await strategy.send(user.email, subject, body);

// What the code actually needs
await emailService.send(user.email, subject, body);
```

**Rule:** If you can't name a second implementor of the interface that would realistically exist, the interface is premature. Remove the abstraction.

---

### Smell 6: Copy-Paste Context Mismatch

LLMs synthesize code from training data across many library versions and frameworks. The generated code may be syntactically valid for an older version of the library, a different framework in the same language, or a language with similar syntax.

**Signals:**
- Callback-style async in a codebase that uses async/await throughout
- Express v4 patterns in an Express v5 project (or Koa, Fastify patterns in an Express codebase)
- Python 2 idioms (`print` statements, `unicode()`, `xrange`) in a Python 3 project
- `github.com/dgrijalva/jwt-go` (archived) instead of `github.com/golang-jwt/jwt/v5`

**Detection strategy:** Check the imported package version against what is installed. Check that the idiom is idiomatic for the project's established style, not just valid for the language.

---

### Smell 7: Missing Edge Cases (Happy-Path Only)

LLMs optimize for code that works in the normal case. Edge case handling — empty collections, nil/null inputs, integer overflow, concurrent access, network timeouts — is often absent or inconsistent.

**Signals:**
- No nil/null check before dereferencing a pointer or accessing a property
- Division operation without zero-denominator guard
- Array access at a computed index without bounds check
- Database operation that assumes exactly one row (no handling for zero or multiple rows)
- No timeout or cancellation context on external I/O

```typescript
// BEFORE — crashes on empty items array, no timeout
async function processOrderItems(orderId: string): Promise<number> {
  const items = await orderRepo.getItems(orderId);
  const total = items.reduce((sum, item) => sum + item.price * item.quantity, 0);
  await paymentService.charge(total);
  return total;
}

// AFTER — guards for empty, zero total, and surfaced errors
async function processOrderItems(orderId: string): Promise<number> {
  const items = await orderRepo.getItems(orderId);
  if (items.length === 0) {
    throw new Error(`processOrderItems: no items found for order ${orderId}`);
  }
  const total = items.reduce((sum, item) => sum + item.price * item.quantity, 0);
  if (total <= 0) {
    throw new Error(`processOrderItems: invalid total ${total} for order ${orderId}`);
  }
  await paymentService.charge(total);
  return total;
}
```

---

### Smell 8: Outdated Patterns

LLMs reflect their training data cutoff. Libraries release breaking changes, deprecate APIs, and retire packages. AI-generated code may use APIs that compile and run but are scheduled for removal, or rely on a package that has been archived.

**Signals:**
- Deprecation warnings in console output or test output that the developer ignored
- Dependencies that `npm audit` or `pip-audit` flags as abandoned
- Framework patterns that match the library's v1 docs, not v2/v3

**Common examples by ecosystem:**

| Ecosystem | Outdated | Current |
|-----------|---------|---------|
| Node.js crypto | `createCipher` (deprecated, insecure) | `createCipheriv` with explicit IV |
| Python async | `asyncio.coroutine` decorator | `async def` |
| Go HTTP | `ioutil.ReadAll` | `io.ReadAll` (Go 1.16+) |
| React | `componentDidMount` class lifecycle | `useEffect` hook |
| JWT (Go) | `dgrijalva/jwt-go` (archived) | `golang-jwt/jwt/v5` |

---

## Hallucinated API Detection

When you see an API call you don't immediately recognize, apply this process before approving:

**Step 1: Identify the exact call.** Note the package, the object type, and the exact method name including casing.

**Step 2: Check the installed version.** In `package.json`, `requirements.txt`, `go.mod`, or `Cargo.toml` — what version is pinned?

**Step 3: Search the official docs for that version.** Not Google — go to the specific library's versioned API reference. LLM-generated code often matches docs from a version 1-2 major versions older.

**Step 4: If in doubt, run it.** A hallucinated method throws at runtime. A quick `node -e` or `python -c` snippet catches it faster than docs research.

**High-risk libraries for hallucination** (large surface area, frequent version churn):
- Prisma (ORM — method names vary significantly across versions)
- AWS SDK v2 vs v3 (completely different import structure)
- LangChain (rapid iteration, APIs change across minor versions)
- SQLAlchemy (v1.x vs v2.x have incompatible query patterns)
- React Query / TanStack Query (v3 vs v4/v5 API surface)

---

## Business Logic Verification

Syntactic correctness does not imply semantic correctness. Use these techniques to verify that AI-generated logic actually implements the requirement:

**Concrete trace.** Pick the simplest non-trivial input and manually trace through the code step by step. Write down the value of each variable at each step. Compare to the expected output.

**Boundary test.** Identify the boundaries in the logic (comparisons, conditional branches, off-by-one arithmetic) and trace with inputs at each boundary: exactly at the threshold, one above, one below.

**Inversion check.** For boolean conditions, ask: "what would a false value here mean?" If the inverted meaning is what the code should actually do, the condition is backwards.

**Domain expert read.** For financial, medical, legal, or compliance logic: if you don't know the domain rules cold, don't approve the code based on reading it. Ask a domain expert to verify the formula or rule.

**Common AI logic errors by category:**

| Category | Common Error |
|----------|-------------|
| Date arithmetic | Off-by-one in day/month boundaries; ignores DST; wrong timezone |
| Financial rounding | Floating point instead of decimal; truncate vs. round vs. bankers' rounding |
| Access control logic | `||` vs `&&` inversion; checks only one of multiple required conditions |
| Sorting | Wrong comparator direction; mutates input array instead of copying |
| String matching | Case-sensitive when case-insensitive required; substring match when exact match needed |

---

## Security Gaps in AI Code

AI-generated code has predictable security blind spots because LLM training data skews toward tutorial-style code that doesn't model threat actors.

**Authorization vs. authentication gap.** AI code reliably adds authentication (`requireAuth` middleware) but frequently omits authorization (does this authenticated user have permission for this specific resource). Review every resource-access endpoint for ownership and role checks.

**Mass assignment vulnerability.** LLMs generate `Object.assign(record, req.body)` or ORM `update(req.body)` patterns that allow callers to overwrite any field, including `role`, `isAdmin`, `ownerId`. Require an explicit allow-list of updatable fields.

```typescript
// BEFORE — mass assignment: caller can set any field including role
await userRepo.update(req.params.id, req.body);

// AFTER — explicit field allow-list
const { displayName, bio, avatarUrl } = req.body;
await userRepo.update(req.params.id, { displayName, bio, avatarUrl });
```

**Missing rate limiting on sensitive endpoints.** AI code generates auth endpoints without rate limiting. Every login, password-reset, OTP, and account-creation endpoint needs throttling.

**Insecure direct object references (IDOR).** AI code uses user-supplied IDs to look up records without confirming ownership. See Smell 3 for the pattern.

**Secret leakage via error messages.** AI error handling often logs full exception objects that may contain connection strings, API responses with keys, or internal path names. Sanitize before logging or returning.

**Input validation gaps.** AI code validates shape (type checking) but rarely validates semantics: numeric ranges, string length limits, allowed character sets, file type verification (not just extension). See `security-patterns-code-review` for complete input validation patterns.

**SSRF in URL-accepting parameters.** When AI code accepts a URL from user input and fetches it server-side, it rarely restricts to safe hosts. This enables Server-Side Request Forgery against internal services.

```python
# BEFORE — SSRF: user supplies any URL, server fetches it
def fetch_webhook_preview(url: str) -> dict:
    response = requests.get(url, timeout=5)
    return response.json()

# AFTER — allowlist of safe schemes and blocked private ranges
import ipaddress
from urllib.parse import urlparse

ALLOWED_SCHEMES = {'https'}
BLOCKED_PREFIXES = ('10.', '172.', '192.168.', '127.', 'localhost')

def fetch_webhook_preview(url: str) -> dict:
    parsed = urlparse(url)
    if parsed.scheme not in ALLOWED_SCHEMES:
        raise ValueError(f"Scheme {parsed.scheme} not allowed")
    if any(parsed.hostname.startswith(p) for p in BLOCKED_PREFIXES):
        raise ValueError("Private/internal hosts not allowed")
    response = requests.get(url, timeout=5)
    response.raise_for_status()
    return response.json()
```

---

## Review Checklist for AI-Generated Code

Use this checklist when a PR is known or suspected to contain AI-generated code.

**Before reading the code:**
- [ ] Does the PR description explain *what* the code does and *why* those choices were made? AI-assisted PRs often have thin descriptions.
- [ ] Is the code consistent with the project's existing idioms, or does it read like a different codebase?

**API verification:**
- [ ] Every external library call verified against installed version docs
- [ ] No imports from packages not in the dependency manifest
- [ ] No calls to methods that don't appear in the current version's API reference

**Logic correctness:**
- [ ] Traced the critical path with at least one concrete example
- [ ] Boolean conditions checked for inversion
- [ ] Date/time arithmetic reviewed for timezone and off-by-one
- [ ] Financial/domain-specific formulas verified against the source specification

**Security:**
- [ ] Every resource-access endpoint has ownership or role check (not just authentication)
- [ ] No mass assignment — updatable fields explicitly listed
- [ ] Sensitive endpoints (auth, OTP, reset) have rate limiting
- [ ] User-supplied URLs not fetched server-side without host validation
- [ ] Error messages don't leak internal paths, connection strings, or stack traces

**Error handling:**
- [ ] No silent `catch` blocks — every catch either rethrows, logs, or returns a typed error
- [ ] Errors carry enough context to diagnose the failure in production
- [ ] External I/O has timeout or cancellation

**Edge cases:**
- [ ] Nil/null inputs handled
- [ ] Empty collections handled
- [ ] Zero-denominator and overflow cases considered
- [ ] Behavior documented for boundary inputs

**Abstraction:**
- [ ] No interface with a single concrete implementor that is never tested via the interface
- [ ] No factory whose only output is one type
- [ ] Simplest design that meets the requirement

---

## Cross-References

- `security-patterns-code-review` — detailed security patterns; IDOR, mass assignment, injection
- `review-code-quality-process` — full PR review workflow; where to embed AI-code checks
- `error-handling-patterns` — correct wrapping and propagation conventions
- `anti-patterns-catalog` — over-abstraction, premature generalization
- `detect-code-smells` — general code smell detection; AI smells are a specialization
