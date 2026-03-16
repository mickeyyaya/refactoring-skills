---
name: testing-patterns
description: Use when writing, reviewing, or diagnosing tests — covers Test Double taxonomy, test smells, testing strategies (AAA, F.I.R.S.T., Test Pyramid), TDD anti-patterns, and a quick-reference classification table
---

# Testing Patterns and Anti-Patterns

## Overview

Classify test doubles, recognize test smells, apply testing strategies, and avoid TDD anti-patterns. Use when writing tests, reviewing test coverage in a PR, or diagnosing slow/fragile/misleading test suites.

---

## Test Double Taxonomy

**Google's preference order: Real > Fake > Stub > Mock**

| Double | What it does | Verifies calls? | Has logic? | Use when |
|--------|-------------|-----------------|------------|----------|
| Dummy | Passed but never used | No | No | Satisfying unused required params |
| Stub | Returns preset values | No | Minimal | Controlling outputs for a specific path |
| Spy | Records calls, delegates to real | Yes (after) | Yes | Verifying call count/args without replacing behavior |
| Mock | Pre-programmed expectations | Yes (during) | No | Strict interaction verification — use sparingly |
| Fake | Simplified working impl | No | Yes | Replacing slow/external systems (in-memory DB, fake API) |

```typescript
// DUMMY
const dummyLogger: Logger = {} as Logger;

// STUB
const stubUserRepo = { findById: (_id: string) => Promise.resolve({ id: "1", name: "Alice" }) };

// SPY
const sendEmailSpy = jest.spyOn(emailService, "send");
await notifyUser(user);
expect(sendEmailSpy).toHaveBeenCalledWith(user.email, expect.any(String));

// MOCK
const mockGateway = { charge: jest.fn().mockResolvedValue({ status: "ok" }) };
await checkout(cart, mockGateway);
expect(mockGateway.charge).toHaveBeenCalledWith(cart.total);

// FAKE
class FakeUserRepository implements UserRepository {
  private store = new Map<string, User>();
  async findById(id: string) { return this.store.get(id) ?? null; }
  async save(user: User) { this.store.set(user.id, user); }
}
```

---

## Test Smells

### 1. The Liar
Passes but does not verify claimed behavior. Assertions always evaluate to true.
```typescript
// SMELL: expect(result).toBeDefined();  // FIX: expect(result).toBe(90);
```

### 2. Excessive Setup
50+ lines before first assertion. Unit under test has too many dependencies.
**Fix:** Factory function accepting only test-relevant params.

### 3. The Giant
One test covers multiple behaviors. Failure does not pinpoint the break.
**Fix:** One behavior per test.

### 4. The Mockery
So many mocks the test verifies the mocking framework, not the system.
**Fix:** Use fakes for heavy deps; keep one mock for the call you are verifying.

### 5. Generous Leftovers
Mutates shared state; tests pass only in specific order.
**Fix:** Each test owns its own setup/teardown.

### 6. Local Hero
Passes locally, fails in CI. Caused by hardcoded paths, ports, timezones, locale.
**Fix:** Inject from environment; use containers for integration tests.

### 7. The Slow Poke
Suite so slow developers skip it. Real I/O, sleeps, missing parallelism.
**Fix:** Fakes for I/O; remove sleeps; parallelize; split unit/integration runs.

### 8. Chain Gang
Tests must run in order. Related to Generous Leftovers.
**Fix:** `beforeEach`/`afterEach`; never assume ordering.

### 9. The Free Ride
New behavior asserted inside existing test instead of its own test.
**Fix:** Separate test per behavior.

---

## Testing Strategies

### AAA Pattern (Arrange-Act-Assert)
```typescript
it("should return 90 when 10% discount applied to 100", () => {
  const price = 100, discountRate = 0.1;         // Arrange
  const result = applyDiscount(price, discountRate); // Act
  expect(result).toBe(90);                        // Assert
});
```
If the three sections are not identifiable at a glance, the test does too much.

### Given-When-Then (BDD)
Maps to business requirements. Preferred for integration and E2E tests.

### F.I.R.S.T. Principles

| Principle | Rule |
|-----------|------|
| **Fast** | Unit tests run in milliseconds |
| **Isolated** | No shared state or ordering dependency |
| **Repeatable** | Same result every run, any environment |
| **Self-validating** | Pass/fail without manual inspection |
| **Timely** | Written before or alongside the code |

### Test Pyramid
```
       /  E2E  \        Few — expensive, slow, high confidence
      /Integr.  \       Some — test component boundaries
     / Unit Tests\      Many — fast, isolated, low cost
```
**Testing Trophy (Dodds):** More integration tests for UI/API layers where integration better reflects user interaction.

---

## TDD Anti-Patterns

| Anti-Pattern | Problem | Fix |
|-------------|---------|-----|
| Tests after the fact | Biased toward confirming implementation, miss edge cases | Write failing test first |
| Testing implementation | Asserting private state breaks on valid refactors | Test observable behavior |
| Mocking what you don't own | Ties tests to library internals | Wrap behind your own interface |
| 100% coverage as goal | Produces tests that touch lines, not verify behavior | Every test should be able to fail |
| Ignoring flaky tests | Erodes trust in entire suite | Fix or delete within same sprint |

---

## Quick Reference

| Smell / Pattern | Category | Severity | Fix |
|-----------------|----------|----------|-----|
| The Liar | Smell | HIGH | Assert actual values |
| Excessive Setup | Smell | MEDIUM | Builder/factory; reduce deps |
| The Giant | Smell | MEDIUM | One behavior per test |
| The Mockery | Smell | HIGH | Replace mocks with fakes |
| Generous Leftovers | Smell | HIGH | Isolate state |
| Local Hero | Smell | HIGH | Inject env config; containers |
| The Slow Poke | Smell | MEDIUM | Fakes for I/O; parallelize |
| Chain Gang | Smell | HIGH | Fully independent tests |
| The Free Ride | Smell | LOW | Separate test per behavior |
| AAA | Strategy | — | Structure every unit test |
| F.I.R.S.T. | Strategy | — | Evaluate against all five properties |
| Test Pyramid | Strategy | — | Many unit, some integration, few E2E |

---

## Cross-References

| Topic | Skill |
|-------|-------|
| Testing dimension in code review | `review-code-quality-process` |
| Test-related code smells | `detect-code-smells` |
| Clean code for testability | `review-solid-clean-code` |
| Anti-patterns catalog | `anti-patterns-catalog` |
