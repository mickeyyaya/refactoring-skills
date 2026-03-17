---
name: ai-generated-code-review
description: Use when reviewing LLM/AI-generated code — covers hallucinated APIs, plausible-but-wrong logic, authorization gaps, shallow error handling, over-abstraction, copy-paste context mismatch, missing edge cases, and outdated patterns with detection strategies and before/after examples in TypeScript, Python, and Go
---

# AI-Generated Code Review

## Overview

AI-generated code fails differently than human-written code. An LLM will confidently invent a plausible-looking method that doesn't exist; it skips auth because tutorials rarely include it.

**The core problem:** Syntactically fluent but semantically unreliable. It passes linters and type checkers yet silently calls methods that don't exist or leaves security-critical paths unguarded.

**When to use:** Any PR with AI assistance markers — unusually consistent formatting, generic variable names, verbose boilerplate, comments explaining obvious things.

**Mindset shift:** Don't ask "is this correct?" Ask "did the AI understand the actual requirements, or generate plausible code for a slightly different problem?"

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

LLM invents method names that sound plausible but don't exist. Common in: date/time libraries, ORMs, SDK clients, testing utilities.

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

**Detection strategy:** Run the code. If you can't, search the official API docs for the exact method name. Don't trust that "it looks right."

### Smell 2: Plausible-but-Wrong Logic

Code runs and looks reasonable, but logic is subtly incorrect. LLMs frequently get: off-by-one in date arithmetic, inverted boolean conditions, wrong operator precedence, reference vs. value comparisons.

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

**Detection strategy:** Trace the logic with a concrete example. Don't read what you expect — trace what it actually does, step by step.

### Smell 3: Missing Authorization Checks

Authentication middleware often gets added; authorization (ownership, role) is frequently absent.

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

### Smell 4: Shallow Error Handling

LLMs generate happy-path code with catch blocks that swallow errors silently or log generic messages that destroy the stack trace.

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

### Smell 5: Over-Abstraction

LLMs default to enterprise patterns — factories, strategy objects, DI containers — even for single-use code.

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

**Rule:** If you can't name a second implementor that would realistically exist, the interface is premature. Remove the abstraction.

### Smell 6: Copy-Paste Context Mismatch

Generated code may be syntactically valid for an older version, a different framework, or a language with similar syntax.

**Signals:**
- Callback-style async in a codebase that uses async/await throughout
- Express v4 patterns in an Express v5 project (or Koa, Fastify patterns in an Express codebase)
- Python 2 idioms (`print` statements, `unicode()`, `xrange`) in a Python 3 project
- `github.com/dgrijalva/jwt-go` (archived) instead of `github.com/golang-jwt/jwt/v5`

**Detection strategy:** Check the imported package version against what is installed. Verify the idiom is idiomatic for the project's style, not just valid for the language.

### Smell 7: Missing Edge Cases (Happy-Path Only)

Edge case handling — empty collections, nil/null inputs, overflow, concurrent access, timeouts — is often absent.

**Signals:**
- No nil/null check before dereferencing a pointer or accessing a property
- Division operation without zero-denominator guard
- Array access at a computed index without bounds check
- Database operation that assumes exactly one row
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

### Smell 8: Outdated Patterns

LLMs reflect their training cutoff — generated code may use deprecated APIs or archived packages. Watch for deprecation warnings, `npm audit`/`pip-audit` hits, and v1 idioms in v2/v3 projects.

| Ecosystem | Outdated | Current |
|-----------|---------|---------|
| Node.js crypto | `createCipher` (deprecated, insecure) | `createCipheriv` with explicit IV |
| Python async | `asyncio.coroutine` decorator | `async def` |
| Go HTTP | `ioutil.ReadAll` | `io.ReadAll` (Go 1.16+) |
| React | `componentDidMount` class lifecycle | `useEffect` hook |
| JWT (Go) | `dgrijalva/jwt-go` (archived) | `golang-jwt/jwt/v5` |

---

## Hallucinated API Detection

1. Identify the exact call — package, object type, method name including casing.
2. Check the installed version in `package.json`, `requirements.txt`, `go.mod`, or `Cargo.toml`.
3. Search the official versioned API docs — LLM code often matches docs 1-2 major versions older.
4. If in doubt, run it. A hallucinated method throws at runtime.

**High-risk libraries:** Prisma, AWS SDK v2/v3, LangChain, SQLAlchemy (v1.x vs v2.x), React Query/TanStack Query (v3 vs v4/v5).

## Business Logic Verification

**Concrete trace.** Trace through the simplest non-trivial input step by step.
**Boundary test.** Trace inputs at each boundary: at the threshold, one above, one below.
**Inversion check.** For booleans, ask: "what would false mean here?" If the inverted meaning is what the code should do, the condition is backwards.
**Domain expert read.** For financial, medical, legal, or compliance logic — if you don't know the domain cold, don't approve based on reading it.

| Category | Common Error |
|----------|-------------|
| Date arithmetic | Off-by-one in day/month boundaries; ignores DST; wrong timezone |
| Financial rounding | Floating point instead of decimal; truncate vs. round vs. bankers' rounding |
| Access control logic | `||` vs `&&` inversion; checks only one of multiple required conditions |
| Sorting | Wrong comparator direction; mutates input array instead of copying |
| String matching | Case-sensitive when case-insensitive required; substring match when exact match needed |

---

## Security Gaps in AI Code

**Authorization vs. authentication gap.** AI reliably adds authentication but omits authorization. Review every resource-access endpoint for ownership and role checks.

**Mass assignment vulnerability.** LLMs generate `Object.assign(record, req.body)` patterns allowing callers to overwrite any field, including `role`, `isAdmin`, `ownerId`. Require an explicit allow-list.

```typescript
// BEFORE — mass assignment: caller can set any field including role
await userRepo.update(req.params.id, req.body);

// AFTER — explicit field allow-list
const { displayName, bio, avatarUrl } = req.body;
await userRepo.update(req.params.id, { displayName, bio, avatarUrl });
```

**Missing rate limiting.** Every login, password-reset, OTP, and account-creation endpoint needs throttling.

**IDOR.** AI code uses user-supplied IDs to look up records without confirming ownership. See Smell 3.

**Secret leakage via error messages.** AI error handling often logs full exception objects containing connection strings or API keys. Sanitize before logging or returning.

**Input validation gaps.** Validates shape (type checking) but rarely semantics: numeric ranges, string length limits, allowed character sets.

**SSRF.** When AI code accepts a URL from user input and fetches it server-side, it rarely restricts to safe hosts.

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

**Before reading the code:**
- [ ] Does the PR description explain *what* the code does and *why* those choices were made?
- [ ] Is the code consistent with the project's existing idioms?

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
