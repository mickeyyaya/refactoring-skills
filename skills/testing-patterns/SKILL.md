---
name: testing-patterns
description: Use when writing, reviewing, or diagnosing tests — covers Test Double taxonomy, test smells, testing strategies (AAA, F.I.R.S.T., Test Pyramid), TDD anti-patterns, and a quick-reference classification table
---

# Testing Patterns and Anti-Patterns

## Overview

This skill defines how to classify test doubles, recognize test smells, apply testing strategies, and avoid TDD anti-patterns. Apply it when writing new tests, reviewing test coverage in a PR, or diagnosing why a test suite is slow, fragile, or misleading.

## When to Use

- When choosing what kind of test double to use for a dependency
- When a test suite has coverage but bugs still slip through
- When tests pass in CI but break locally (or vice versa)
- When reviewing the Testing dimension of a code review (see `review-code-quality-process`)
- When onboarding a team to TDD and establishing shared vocabulary

---

## Test Double Taxonomy

A **test double** is any object that stands in for a real dependency during a test. The five types differ in what they verify and how much they simulate.

**Google's preference order: Real > Fake > Stub > Mock**

Minimize mock usage. Prefer real implementations when fast enough; prefer fakes when the real thing is too slow or has side effects.

| Double | What it does | Verifies calls? | Has logic? | Prefer when |
|--------|-------------|-----------------|------------|-------------|
| Dummy | Passed but never used | No | No | Satisfying required parameters you don't care about |
| Stub | Returns preset values | No | Minimal | Controlling outputs to test a specific path |
| Spy | Records calls, delegates to real implementation | Yes (after the fact) | Yes (wraps real) | Verifying call count/args without fully replacing behavior |
| Mock | Pre-programmed expectations, fails if not met | Yes (during execution) | No | Strict interaction verification — use sparingly |
| Fake | Simplified working implementation | No | Yes (real logic) | Replacing slow or external systems (in-memory DB, fake API) |

### TypeScript Examples

```typescript
// DUMMY — never used, just satisfies a required parameter
const dummyLogger: Logger = {} as Logger;
userService.create({ name: "Alice" }, dummyLogger);

// STUB — returns preset data, no verification
const stubUserRepo = {
  findById: (_id: string) => Promise.resolve({ id: "1", name: "Alice" }),
};

// SPY — wraps real implementation, records calls
const sendEmailSpy = jest.spyOn(emailService, "send");
await notifyUser(user);
expect(sendEmailSpy).toHaveBeenCalledWith(user.email, expect.any(String));

// MOCK — pre-programmed; fails if expectation not met
const mockPaymentGateway = {
  charge: jest.fn().mockResolvedValue({ status: "ok" }),
};
await checkout(cart, mockPaymentGateway);
expect(mockPaymentGateway.charge).toHaveBeenCalledWith(cart.total);

// FAKE — in-memory implementation with real logic
class FakeUserRepository implements UserRepository {
  private store = new Map<string, User>();
  async findById(id: string) { return this.store.get(id) ?? null; }
  async save(user: User) { this.store.set(user.id, user); }
}
```

---

## Test Smells

Test smells indicate that tests are poorly structured, unreliable, or testing the wrong things. Each smell has a name, a description, and a fix.

### 1. The Liar

**What it is:** A test that passes consistently but does not actually verify the behavior it claims to test. Often caused by assertions that always evaluate to true.

```typescript
// SMELL — assertion always passes
it("should calculate the discount", () => {
  const result = applyDiscount(100, 0.1);
  expect(result).toBeDefined(); // never fails
});

// FIX — assert the actual value
expect(result).toBe(90);
```

### 2. Excessive Setup

**What it is:** 50+ lines of setup before the first assertion. Signals the unit under test has too many dependencies, or the test is not focused enough.

```typescript
// SMELL
beforeEach(() => {
  db = createTestDatabase();
  repo = new UserRepository(db);
  emailClient = new MockEmailClient();
  logger = new ConsoleLogger("test");
  cache = new RedisCache({ host: "localhost" });
  service = new UserService(repo, emailClient, logger, cache);
  // ... 15 more lines
});

// FIX — use a factory function that accepts only the parameters relevant to each test
function buildService(overrides: Partial<UserServiceDeps> = {}) {
  return new UserService({ repo: fakeRepo, emailClient: fakeEmail, ...overrides });
}
```

### 3. The Giant

**What it is:** One test method that tests multiple distinct behaviors. When it fails, you cannot tell which behavior broke.

```typescript
// SMELL — tests 4 behaviors in one test
it("should handle user lifecycle", async () => {
  const user = await service.create({ name: "Alice" });
  expect(user.id).toBeDefined();
  await service.update(user.id, { name: "Bob" });
  const updated = await service.findById(user.id);
  expect(updated?.name).toBe("Bob");
  await service.delete(user.id);
  expect(await service.findById(user.id)).toBeNull();
});

// FIX — one behavior per test
it("should return an id on create", ...);
it("should persist updated name", ...);
it("should return null after delete", ...);
```

### 4. The Mockery

**What it is:** So many mocks that the test verifies the mocking framework, not the system under test. The implementation could be completely broken but the mocks return "correct" values.

```typescript
// SMELL — mocking everything, testing nothing real
it("should process payment", async () => {
  mockRepo.findUser.mockResolvedValue(fakeUser);
  mockInventory.checkStock.mockResolvedValue(true);
  mockGateway.charge.mockResolvedValue({ success: true });
  mockNotifier.send.mockResolvedValue(undefined);
  const result = await orderService.process(orderId);
  expect(result.status).toBe("completed"); // mocks guaranteed this
});

// FIX — use a Fake for the heavy dependency; keep only one mock for the one call you're verifying
```

### 5. Generous Leftovers

**What it is:** A test mutates shared state and leaves it for subsequent tests to depend on. Tests pass only in a specific order.

```typescript
// SMELL — global mutation
let sharedUser: User;
it("creates a user", async () => {
  sharedUser = await service.create({ name: "Alice" }); // leaks state
});
it("updates the user", async () => {
  await service.update(sharedUser.id, { name: "Bob" }); // depends on prior test
});

// FIX — each test owns its own setup and teardown
```

### 6. Local Hero

**What it is:** A test passes on the developer's machine but fails in CI. Caused by environment-specific values (file paths, time zones, locale, port availability, local API keys).

```typescript
// SMELL
const config = { dbUrl: "postgresql://localhost:5432/mydb" }; // hardcoded local

// FIX — inject from environment; use container or testcontainers for integration tests
const config = { dbUrl: process.env.TEST_DB_URL ?? "postgresql://localhost:5432/testdb" };
```

### 7. The Slow Poke

**What it is:** A test (or suite) takes so long that developers avoid running it. Often caused by real network/disk I/O, sleeps, or missing parallelism.

**Fix:** Replace real I/O with fakes; remove `setTimeout`/`sleep`; parallelize independent tests; split unit and integration test runs.

### 8. Chain Gang

**What it is:** Tests must run in a specific order to pass. Related to Generous Leftovers — the shared state is not cleaned between tests.

**Fix:** Treat each test as isolated. Use `beforeEach` to set up, `afterEach` to tear down. Never assume test ordering.

### 9. The Free Ride

**What it is:** Instead of writing a new test for a new behavior, an assertion is added to an existing test. Makes failures harder to diagnose.

```typescript
// SMELL — second assertion is testing different behavior
it("should calculate discount", () => {
  expect(applyDiscount(100, 0.1)).toBe(90);
  expect(applyDiscount(0, 0.1)).toBe(0); // free ride — separate test needed
});
```

---

## Testing Strategies

### AAA Pattern (Arrange-Act-Assert)

Structure every test in three clearly separated sections.

```typescript
it("should return 90 when 10% discount applied to 100", () => {
  // Arrange
  const price = 100;
  const discountRate = 0.1;

  // Act
  const result = applyDiscount(price, discountRate);

  // Assert
  expect(result).toBe(90);
});
```

Rule: If you cannot identify the three sections at a glance, the test is doing too much.

### Given-When-Then (BDD Variant)

Equivalent to AAA with language that maps to business requirements. Preferred for integration and E2E tests where the scenario needs to read like a specification.

```
Given a user with a valid subscription
When they request a premium feature
Then the feature is returned without an upgrade prompt
```

### F.I.R.S.T. Principles

| Principle | Description |
|-----------|-------------|
| **Fast** | Unit tests must run in milliseconds. Slow tests get skipped. |
| **Isolated** | No shared state between tests. No ordering dependency. |
| **Repeatable** | Same result every run, in any environment. |
| **Self-validating** | Pass or fail without manual inspection of output. |
| **Timely** | Written before or alongside the code — not months later. |

### Test Pyramid

```
         /\
        /E2E\         Few — expensive, slow, high confidence
       /------\
      /Integr. \      Some — test component boundaries
     /----------\
    /  Unit Tests \   Many — fast, isolated, low cost
   /--------------\
```

- Unit tests verify individual functions and classes in isolation.
- Integration tests verify that components work together (DB, queue, cache).
- E2E tests verify critical user journeys through the full stack.

**Testing Trophy (Kent C. Dodds):** Emphasizes more integration tests than unit tests for UI and API layers, where integration better reflects how users actually interact with the system.

---

## TDD Anti-Patterns

### Writing Tests After the Fact

Writing tests after implementation means tests are biased toward confirming the implementation exists, not toward specifying the expected behavior. Tests written post-hoc often miss edge cases the implementation did not encounter.

**Rule:** Write the failing test first. Run it. See it fail. Then implement.

### Testing Implementation, Not Behavior

Tests that assert private methods, internal state, or exact call sequences break on valid refactors — even when behavior is unchanged.

```typescript
// ANTI-PATTERN — testing implementation
expect(service["_cache"].has(userId)).toBe(true); // private field

// CORRECT — testing observable behavior
const result1 = await service.findUser(userId);
const result2 = await service.findUser(userId);
expect(mockRepo.findById).toHaveBeenCalledTimes(1); // cache was used
```

### Mocking What You Don't Own

Mocking third-party libraries (e.g., mocking Axios, Prisma, or AWS SDK directly) ties tests to the library's internal API. When the library upgrades, your mocks break even though your code is correct.

**Fix:** Wrap third-party clients behind an interface you own. Mock your interface, not the library.

### 100% Coverage as the Goal

Chasing a coverage number produces tests that exist to touch lines, not to verify behavior. Coverage is a floor, not a ceiling.

**Rule:** Every test should be able to fail. If you cannot imagine a code change that would make a test fail, delete the test.

### Ignoring Flaky Tests

A flaky test that is skipped, re-run until green, or quarantined permanently is worse than no test. It erodes trust in the entire suite.

**Rule:** Fix or delete flaky tests within the same sprint they appear. Never commit a `.skip` without a ticket reference.

---

## Quick Reference

| Smell / Pattern | Category | Severity | Fix |
|-----------------|----------|----------|-----|
| The Liar | Smell | HIGH | Assert actual values, not just existence |
| Excessive Setup | Smell | MEDIUM | Builder/factory functions; reduce dependencies |
| The Giant | Smell | MEDIUM | One behavior per test |
| The Mockery | Smell | HIGH | Replace mocks with fakes; test real behavior |
| Generous Leftovers | Smell | HIGH | Isolate state; use beforeEach/afterEach |
| Local Hero | Smell | HIGH | Inject env config; use containers |
| The Slow Poke | Smell | MEDIUM | Replace I/O with fakes; parallelize |
| Chain Gang | Smell | HIGH | Treat each test as fully independent |
| The Free Ride | Smell | LOW | Extract separate test per behavior |
| Dummy | Double | — | Satisfying unused required parameters |
| Stub | Double | — | Controlling return values |
| Spy | Double | — | Verifying calls without replacing behavior |
| Mock | Double | — | Strict interaction verification (use sparingly) |
| Fake | Double | — | Replacing slow/external systems (preferred) |
| AAA | Strategy | — | Structure every unit test |
| F.I.R.S.T. | Strategy | — | Evaluate any test against all five properties |
| Test Pyramid | Strategy | — | Ratio guide: many unit, some integration, few E2E |

---

## Cross-References

| Topic | Related Skill |
|-------|--------------|
| Testing dimension in code review | `review-code-quality-process` → Dimension 6 |
| Test-related code smells in production code | `detect-code-smells` |
| Clean code principles that make code testable | `review-solid-clean-code` |
| Anti-patterns in testing and other domains | `anti-patterns-catalog` |
