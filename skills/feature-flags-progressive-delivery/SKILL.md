---
name: feature-flags-progressive-delivery
description: Use when designing or reviewing feature flag systems, progressive delivery pipelines, A/B testing infrastructure, or rollout strategies — covers feature toggles, canary/blue-green/ring deployments, percentage rollouts, kill switches, flag lifecycle, targeting rules, user segments, experiment design, and anti-patterns with TypeScript examples
---

# Feature Flags and Progressive Delivery

## Overview

Feature flags (also called feature toggles or feature switches) decouple deployment from release, letting teams ship code dark and turn it on for targeted users without a new deployment. Combined with progressive delivery strategies like canary releases, blue-green deployments, and ring deployments, they form the backbone of modern continuous delivery.

**When to use:** Designing a feature rollout pipeline; reviewing flag evaluation logic; auditing rollback/kill-switch implementations; designing A/B testing or experimentation infrastructure; reviewing flag hygiene and lifecycle management.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Feature Flag / Toggle | Gate code paths behind runtime-evaluated conditions | Hardcoded flags, no remote config, boolean trap |
| Progressive Delivery | Gradually shift traffic to new code paths | Big-bang releases, no health gate between rollout stages |
| Canary Release | Route a small percentage of traffic to new version | No automatic rollback on error spike |
| Blue-Green Deployment | Two identical environments; switch routing instantly | Shared databases making switchover unsafe |
| Ring Deployment | Concentric user rings (internal → beta → GA) | Rings with no dwell time or health checks |
| Percentage Rollout | Gradual rollout by user percentage | Non-sticky allocation; user sees flag flip each request |
| Kill Switch | Instant off switch for a feature in production | Kill switch itself is flag-gated or takes >1 second |
| Flag Lifecycle | Create → active → cleanup → delete | Stale flags accumulating in codebase, flag debt |
| A/B Testing | Randomized controlled experiment with metrics | Peeking at results early, multiple comparisons, survivorship bias |
| Targeting Rules | Evaluate flag per user context (segment, attribute) | Overly complex rule trees, unbounded rule chains |

---

## Patterns in Detail

### 1. Feature Flags / Feature Toggles / Feature Switches

Feature flags wrap code behind a conditional evaluated at runtime against a remote configuration store. They come in four types with different lifespans:

| Type | Lifespan | Example |
|------|----------|---------|
| Release toggle | Days–weeks | Enable new checkout flow for rollout |
| Experiment toggle | Days–weeks | A/B test new recommendation algorithm |
| Ops toggle | Hours–days | Kill switch for expensive background job |
| Permission toggle | Long-lived | Enable premium feature for paid users |

**Red Flags:**
- Hardcoded boolean `if (NEW_FEATURE_ENABLED)` compiled into the binary — not remotely controllable
- Flag evaluated per request but allocation is not sticky — user sees different behavior across requests
- Flag value fetched synchronously on the hot path — blocks request on config service latency
- Boolean trap: `getFlag("payment", true, false)` — positional booleans, unclear which is on/off

**TypeScript — simple flag client with cached evaluation:**
```typescript
interface FlagContext {
  userId: string;
  email?: string;
  plan?: 'free' | 'pro' | 'enterprise';
  region?: string;
  [key: string]: string | undefined;
}

interface FlagClient {
  isEnabled(flagKey: string, context: FlagContext): boolean;
  getVariant(flagKey: string, context: FlagContext): string;
}

class CachedFlagClient implements FlagClient {
  private cache = new Map<string, { value: boolean | string; expiresAt: number }>();

  constructor(
    private readonly remoteConfig: RemoteConfigService,
    private readonly ttlMs = 30_000,
  ) {}

  isEnabled(flagKey: string, context: FlagContext): boolean {
    const cacheKey = `${flagKey}:${context.userId}`;
    const cached = this.cache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) return cached.value as boolean;

    const value = this.remoteConfig.evaluateFlag(flagKey, context);
    this.cache.set(cacheKey, { value, expiresAt: Date.now() + this.ttlMs });
    return value as boolean;
  }

  getVariant(flagKey: string, context: FlagContext): string {
    return this.remoteConfig.evaluateVariant(flagKey, context);
  }
}

// Usage — explicit context, no boolean trap
const flags = new CachedFlagClient(remoteConfig);
if (flags.isEnabled('new-checkout-flow', { userId: user.id, plan: user.plan })) {
  return renderNewCheckout(cart);
}
return renderLegacyCheckout(cart);
```

---

### 2. Progressive Delivery Strategies

Progressive delivery means gradually rolling out changes rather than a single big-bang release. The primary strategies are canary release, blue-green deployment, and ring deployment.

#### Canary Release

Route a small percentage of production traffic to the new version. Monitor error rates, latency, and business metrics. Automatically roll back if health gates fail.

**Red Flags:**
- No automated rollback trigger — humans must notice and act manually
- Canary traffic too small for statistical significance (< 1% on low-traffic services)
- Canary routes only internal users — skips the real traffic distribution
- No dwell time at each percentage tier before advancing

**TypeScript — canary router with health gate:**
```typescript
interface CanaryConfig {
  flagKey: string;
  percentages: number[];   // [1, 5, 10, 25, 50, 100]
  dwellMinutes: number;
  errorRateThreshold: number;
  p99LatencyThresholdMs: number;
}

class CanaryRouter {
  constructor(
    private readonly flags: FlagClient,
    private readonly metrics: MetricsService,
  ) {}

  async advanceOrRollback(config: CanaryConfig): Promise<'advanced' | 'rolled-back'> {
    const health = await this.metrics.snapshot(config.flagKey);

    if (
      health.errorRate > config.errorRateThreshold ||
      health.p99LatencyMs > config.p99LatencyThresholdMs
    ) {
      await this.flags.setPercentage(config.flagKey, 0);
      await this.metrics.alert(`Canary rolled back: ${config.flagKey}`, health);
      return 'rolled-back';
    }

    const current = await this.flags.getPercentage(config.flagKey);
    const nextTier = config.percentages.find((p) => p > current);
    if (nextTier !== undefined) {
      await this.flags.setPercentage(config.flagKey, nextTier);
    }
    return 'advanced';
  }
}
```

#### Blue-Green Deployment

Maintain two identical production environments (blue and green). Route all traffic to blue. Deploy to green. Run smoke tests. Switch the load balancer to green. Blue becomes the instant rollback target.

**Red Flags:**
- Shared database schema changes not backward-compatible with the blue version
- No smoke test gate before switching the load balancer
- Blue environment torn down immediately — no rollback window
- Database migrations applied before the load balancer switch — cannot roll back

**TypeScript — blue-green switchover:**
```typescript
class BlueGreenDeployer {
  async deploy(newVersion: string): Promise<void> {
    const standby = await this.getStandbySlot();   // 'blue' or 'green'
    await this.deployToSlot(standby, newVersion);
    await this.runSmokeTests(standby);              // throws on failure
    await this.loadBalancer.switchTo(standby);
    await this.metrics.waitForSteadyState(120_000);

    const errorRate = await this.metrics.errorRate(standby);
    if (errorRate > 0.01) {
      await this.rollback();
      throw new Error(`Blue-green rollback: error rate ${errorRate}`);
    }
  }

  async rollback(): Promise<void> {
    const active = await this.loadBalancer.getActiveSlot();
    const previous = active === 'blue' ? 'green' : 'blue';
    await this.loadBalancer.switchTo(previous);
  }
}
```

#### Ring Deployment

Deploy in concentric rings: internal (dogfood) → early adopters (beta) → general availability. Each ring is a gate; the deployment only advances after health checks pass.

**Red Flags:**
- Rings have no minimum dwell time — a slow-burning bug escapes to GA
- Ring 0 (internal) is too small to surface real-world failures
- No health check automation between rings — advancement is manual and inconsistent

---

### 3. Rollout Strategies — Percentage Rollout and Sticky Allocation

A percentage rollout gradually exposes a feature to an increasing fraction of users. Correct sticky allocation ensures a user always gets the same treatment on every request.

**Red Flags:**
- Non-sticky allocation: `Math.random() < 0.1` — 10% chance per request, not per user
- Using session ID instead of user ID for stickiness — breaks across devices
- Rollout percentage stored per-request, not persisted — restarts reset exposure
- No logging of flag assignment — impossible to diagnose inconsistent behavior

**TypeScript — deterministic sticky allocation using hash:**
```typescript
import { createHash } from 'crypto';

function isUserInRollout(flagKey: string, userId: string, percentage: number): boolean {
  if (percentage <= 0) return false;
  if (percentage >= 100) return true;

  // Hash is deterministic: same userId+flagKey always produces same bucket
  const hash = createHash('sha256')
    .update(`${flagKey}:${userId}`)
    .digest('hex');

  // Take first 8 hex chars → 32-bit int, map to 0–99
  const bucket = parseInt(hash.slice(0, 8), 16) % 100;
  return bucket < percentage;
}

// Example: gradual rollout
const inRollout = isUserInRollout('new-dashboard', user.id, 25);
```

---

### 4. Kill Switch and Circuit Breaker / Rollback Patterns

A kill switch is an ops toggle designed to instantly disable a feature in production. A circuit breaker automates this based on observed error rates.

**Red Flags:**
- Kill switch evaluation depends on the same broken service the flag is meant to disable
- Kill switch takes more than one second to propagate — during an incident this is too slow
- Kill switch is itself behind another flag — adds a dependency chain that fails during incidents
- No alert when a kill switch is activated — operators are not notified

**TypeScript — kill switch with local fallback:**
```typescript
class KillSwitchClient {
  private localOverrides = new Map<string, boolean>();

  constructor(
    private readonly remoteFlags: FlagClient,
    private readonly localConfigPath: string,  // file-based fallback
  ) {
    this.loadLocalOverrides();
  }

  isKilled(featureKey: string): boolean {
    // Local file takes priority — survives remote config outage
    if (this.localOverrides.has(featureKey)) {
      return this.localOverrides.get(featureKey)!;
    }
    try {
      return this.remoteFlags.isEnabled(`kill-switch:${featureKey}`, { userId: 'system' });
    } catch {
      return false;  // fail open — do not kill the feature if config is unavailable
    }
  }

  private loadLocalOverrides(): void {
    try {
      const raw = fs.readFileSync(this.localConfigPath, 'utf8');
      const config = JSON.parse(raw) as Record<string, boolean>;
      for (const [key, value] of Object.entries(config)) {
        this.localOverrides.set(key, value);
      }
    } catch {
      // No local overrides file — fine
    }
  }
}
```

Cross-reference: `microservices-resilience-patterns` — Circuit Breaker for auto-tripping based on error rates; `error-handling-patterns` — Circuit Breaker implementation.

---

### 5. Flag Lifecycle, Flag Debt, and Cleanup Strategies

Every feature flag has a lifecycle: created, active, graduated (code permanently on or off), and deleted. Stale flags that are never removed accumulate as flag debt: dead branches, untestable code paths, and cognitive overhead.

**Red Flags:**
- Release toggles older than 30 days with no graduation plan
- Flag checked in 20 different files — removal requires a wide refactor
- No owner or expiry date recorded for flags
- Flag removed from config but code still checks it — dead conditional that always evaluates to default

**TypeScript — flag registry with expiry tracking:**
```typescript
interface FlagDefinition {
  key: string;
  type: 'release' | 'experiment' | 'ops' | 'permission';
  owner: string;
  createdAt: string;       // ISO-8601
  expiresAt?: string;      // Required for release and experiment types
  defaultValue: boolean;
  description: string;
}

// Flag registry — single source of truth, checked into source control
export const FLAG_REGISTRY: FlagDefinition[] = [
  {
    key: 'new-checkout-flow',
    type: 'release',
    owner: 'platform-team',
    createdAt: '2025-10-01T00:00:00Z',
    expiresAt: '2025-11-01T00:00:00Z',
    defaultValue: false,
    description: 'Enables redesigned checkout UI — remove after full rollout',
  },
];

// CI check: fail if any release/experiment flag is past expiry
function checkFlagDebt(registry: FlagDefinition[]): string[] {
  const now = new Date();
  return registry
    .filter((f) => f.expiresAt && new Date(f.expiresAt) < now)
    .map((f) => `STALE FLAG: ${f.key} expired ${f.expiresAt} (owner: ${f.owner})`);
}
```

**Cleanup process:**
1. Graduate flag: remove conditional, keep only the winning code path
2. Delete flag from remote config store
3. Remove flag definition from registry
4. Remove all `isEnabled('flag-key', ...)` call sites
5. Verify with grep that no references remain

---

### 6. A/B Testing, Experiments, Multivariate Tests, and Cohorts

A/B testing uses feature flags to randomly assign users to control or treatment groups and measures the effect on a metric. Multivariate tests evaluate multiple variants simultaneously. Cohort analysis tracks a fixed group of users over time.

**Red Flags:**
- Peeking at results before reaching statistical significance — inflates false positive rate
- Multiple comparisons without correction (Bonferroni, Benjamini-Hochberg) — spurious wins
- Experiment runs during a special event (holiday, outage) — results do not generalize
- Assignment logged but exposure not logged — dilution bias from users who never saw the variant
- Cohort is not fixed — users drift in/out, making longitudinal comparison invalid

**TypeScript — experiment assignment and exposure logging:**
```typescript
interface ExperimentAssignment {
  experimentKey: string;
  variant: 'control' | 'treatment' | string;
  userId: string;
  assignedAt: string;
}

class ExperimentService {
  constructor(
    private readonly flags: FlagClient,
    private readonly analytics: AnalyticsService,
  ) {}

  assign(experimentKey: string, context: FlagContext): ExperimentAssignment {
    const variant = this.flags.getVariant(experimentKey, context);

    const assignment: ExperimentAssignment = {
      experimentKey,
      variant,
      userId: context.userId,
      assignedAt: new Date().toISOString(),
    };

    // Log exposure at the point of assignment, not at the point of metric collection
    this.analytics.track('experiment_exposure', assignment);
    return assignment;
  }
}

// Multivariate: getVariant returns 'control' | 'variant_a' | 'variant_b'
const { variant } = experimentService.assign('recommendation-algo', userContext);
switch (variant) {
  case 'variant_a': return collabFilterRecs(userId);
  case 'variant_b': return contentFilterRecs(userId);
  default:          return legacyRecs(userId);
}
```

Cross-reference: `observability-patterns` — Metrics and dashboards for tracking experiment health and business metrics during rollout.

---

### 7. Targeting Rules, User Segments, and Context Evaluation

Targeting rules evaluate a flag against user context to produce a value. Rules can target individual users, named segments (e.g., beta users, enterprise accounts), or computed attributes (region, plan, device type).

**Red Flags:**
- Rules reference volatile attributes (session state) instead of stable identifiers
- Unbounded rule chain: 50 rules evaluated sequentially per request — latency impact
- Segment membership re-computed on every flag evaluation instead of cached
- No fallback default when context attribute is missing — evaluation throws instead of defaulting
- Targeting rules encode business logic that belongs in the application layer

**TypeScript — rule evaluator with safe defaults:**
```typescript
type RuleOperator = 'equals' | 'contains' | 'startsWith' | 'in' | 'semverGte';

interface TargetingRule {
  attribute: keyof FlagContext;
  operator: RuleOperator;
  value: string | string[];
  serveVariant: string;
}

function evaluateRules(
  rules: TargetingRule[],
  context: FlagContext,
  defaultVariant: string,
): string {
  for (const rule of rules) {
    const ctxValue = context[rule.attribute];
    if (ctxValue === undefined) continue;  // safe: skip rules with missing attributes

    const matched = matchRule(ctxValue, rule.operator, rule.value);
    if (matched) return rule.serveVariant;
  }
  return defaultVariant;
}

function matchRule(
  actual: string,
  operator: RuleOperator,
  expected: string | string[],
): boolean {
  switch (operator) {
    case 'equals':    return actual === expected;
    case 'contains':  return typeof expected === 'string' && actual.includes(expected);
    case 'in':        return Array.isArray(expected) && expected.includes(actual);
    case 'startsWith':return typeof expected === 'string' && actual.startsWith(expected);
    default:          return false;
  }
}
```

---

### 8. Anti-Patterns

#### Flag Explosion

Creating dozens of flags without governance leads to an untestable matrix of combinations. With N boolean flags, there are 2^N possible states — most of which are never tested.

**Fix:** Gate new flags through a review process. Enforce maximum active release toggle count (e.g., 10 per service). Require an expiry date for every release flag.

#### Nested Flags

One flag checks another flag inside its gated code path. This creates hidden dependencies: disabling the outer flag also disables the inner flag's effect, and the dependency is invisible in the config system.

```typescript
// WRONG — nested flags, hidden dependency
if (flags.isEnabled('new-billing', ctx)) {
  if (flags.isEnabled('new-billing-v2', ctx)) {
    // This path is dead if new-billing is off
  }
}

// CORRECT — use a single flag with variants
const billingVariant = flags.getVariant('billing-experience', ctx);
// 'legacy' | 'v1' | 'v2'
```

#### Boolean Trap in Flag APIs

```typescript
// WRONG — which boolean is "on"?
flagClient.evaluate('checkout', true, false, userCtx);

// CORRECT — named config object, no boolean trap
flagClient.evaluate('checkout', { defaultValue: false, context: userCtx });
```

#### Flag as Feature Specification

Flags are not a substitute for requirements. If a flag is the only documentation for what a feature does, the flag description must be explicit. A flag named `"exp-12"` with no description creates permanent confusion.

#### Long-Lived Release Toggles (Stale Flags)

Release toggles intended for a two-week rollout that survive for six months are flag debt. They add dead branches, confuse new engineers, and block refactoring. Enforce expiry dates and fail CI when flags are past their expiry date.

**Anti-pattern summary:**

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Flag Explosion** | Too many concurrent flags, 2^N state matrix | Governance gate, max active count, mandatory expiry |
| **Nested Flags** | Flag gating checks another flag | Use single flag with variants instead |
| **Boolean Trap** | Positional booleans in flag API | Named config objects |
| **Stale Flags** | Release toggles alive >30 days | Expiry dates, CI lint check, cleanup sprint |
| **Shared Mutable Flag State** | Multiple services writing same flag | One owner per flag, read-only for consumers |
| **Flag as Config** | Storing business config (prices, limits) in a feature flag | Use a separate config store |

---

## Cross-References

- `testing-patterns` — Testing flag-gated code: test each variant independently; use flag override helpers in tests; avoid flag evaluation in unit tests by injecting boolean directly
- `observability-patterns` — Instrument flag evaluations: log variant assigned, track metrics per variant, alert on error rate divergence between control and treatment
- `microservices-resilience-patterns` — Circuit breaker integration with kill switches; progressive delivery health gates; canary rollback triggers based on SLO breach
- `error-handling-patterns` — Circuit Breaker pattern reused in kill switch automation; graceful degradation when flag config service is unavailable
