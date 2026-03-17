---
name: developer-experience-patterns
description: Use when designing or reviewing developer tooling, monorepo structure, dev environments, onboarding flows, or internal platforms — covers Monorepo tooling (Nx/Turborepo), dev containers, golden path / platform engineering, local-prod parity, fast feedback loops, DX-first API design, developer onboarding, and DX anti-patterns with TypeScript, YAML, and Dockerfile examples
---

# Developer Experience Patterns

## Overview

Poor developer experience compounds over time: slow builds frustrate contributors, undocumented environments block onboarding, and inconsistent tooling creates invisible silos. Use this guide when designing internal platforms, reviewing build configurations, auditing onboarding docs, or evaluating the ergonomics of a developer-facing API.

**When to use:** Setting up a new monorepo, auditing CI pipeline speed, designing an internal developer platform (IDP), evaluating a new service template, reviewing a contributing guide, or assessing why engineers avoid a particular tool.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Monorepo Tooling | Nx / Turborepo compute affected builds from dependency graph | Rebuilding all packages on every commit |
| Dev Containers | Reproducible environment declared as code via `.devcontainer` | "Works on my machine" — setup differs per laptop |
| Golden Path | Opinionated service templates and internal platform reduce decision fatigue | Every team reinvents CI config from scratch |
| Local-Prod Parity | Seed scripts, test-data factories, and env management mirror production data shapes | Tests pass locally, fail in CI due to missing seed data |
| Fast Feedback Loops | Hot reload, incremental builds, test watch mode surface errors in seconds | 30-minute build for a one-line change |
| DX-First API Design | Ergonomic SDKs, descriptive errors, auto-generated docs make APIs self-explaining | Callers must read the source to understand error shapes |
| Developer Onboarding | Setup scripts, contributing guides, and ADRs reduce time-to-first-PR | New hire takes two weeks to run the app locally |
| DX Anti-Patterns | Tribal knowledge, manual setup steps, flaky environments erode confidence | Undocumented environment variables required at runtime |

---

## Patterns in Detail

### 1. Monorepo Tooling (Nx, Turborepo, Affected Builds)

A monorepo collocates multiple packages or services in one repository. The key win is **affected builds**: only rebuild and retest the packages that changed, computed from the dependency graph.

**Red Flags:**
- `npm run build` at the repo root rebuilds all packages unconditionally
- No remote cache — every CI run pays the full build cost
- No clear dependency graph — circular imports between packages
- Manually updated lists of "affected" services in scripts

**Nx — affected build commands:**
```bash
npx nx affected --target=build --base=origin/main  # only changed packages
npx nx graph                                        # visualize dependency graph
npx nx run-many --target=test --all --parallel=4   # parallel test with cache
```

**`nx.json` — remote cache configuration (excerpt):**
```json
{
  "tasksRunnerOptions": {
    "default": {
      "runner": "nx/tasks-runners/default",
      "options": {
        "cacheableOperations": ["build", "test", "lint"],
        "remoteCache": { "url": "https://nx-cache.internal.example.com" }
      }
    }
  },
  "targetDefaults": {
    "build": { "dependsOn": ["^build"], "outputs": ["{projectRoot}/dist"] },
    "test":  { "dependsOn": ["build"] }
  }
}
```

**`turbo.json` pipeline (Turborepo alternative):**
```json
{
  "$schema": "https://turbo.build/schema.json",
  "pipeline": {
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**", ".next/**"] },
    "test":  { "dependsOn": ["build"], "outputs": ["coverage/**"] },
    "lint":  { "outputs": [] },
    "dev":   { "cache": false, "persistent": true }
  },
  "remoteCache": { "signature": true }
}
```

**TypeScript — programmatic affected detection:**
```typescript
import { execSync } from 'child_process';

function getAffectedPackages(base = 'origin/main'): string[] {
  const output = execSync(
    `npx nx show projects --affected --base=${base} --json`,
    { encoding: 'utf8' }
  );
  return JSON.parse(output) as string[];
}
```

Cross-reference: `cicd-pipeline-patterns` — Pipeline optimization and caching strategies.

---

### 2. Dev Containers and Environment-as-Code

A dev container defines the full development environment (runtime, tools, extensions) as checked-in code. Every developer and CI job starts from an identical, reproducible environment.

**Red Flags:**
- README says "install Node 18" without specifying exact version or toolchain
- Missing environment variables discovered only at runtime
- Works on my machine — no parity between developer laptops and CI
- Dependencies installed manually rather than scripted

**`.devcontainer/devcontainer.json`:**
```json
{
  "name": "api-service",
  "dockerComposeFile": "../docker-compose.dev.yml",
  "service": "api",
  "workspaceFolder": "/workspace",
  "features": {
    "ghcr.io/devcontainers/features/node:1": { "version": "20" },
    "ghcr.io/devcontainers/features/docker-in-docker:2": {}
  },
  "customizations": {
    "vscode": {
      "extensions": ["dbaeumer.vscode-eslint", "esbenp.prettier-vscode"],
      "settings": { "editor.formatOnSave": true }
    }
  },
  "postCreateCommand": "npm ci && npm run db:migrate",
  "remoteEnv": { "DATABASE_URL": "${localEnv:DATABASE_URL}" }
}
```

**`docker-compose.dev.yml` — key sections (full file omits nothing structurally significant):**
```yaml
services:
  api:
    build: { context: ., dockerfile: Dockerfile.dev }
    volumes: [".:/workspace:cached", "node_modules:/workspace/node_modules"]
    ports: ["3000:3000"]
    environment:
      DATABASE_URL: postgres://dev:dev@db:5432/appdb
      REDIS_URL: redis://cache:6379
    depends_on:
      db: { condition: service_healthy }

  db:
    image: postgres:16-alpine
    environment: { POSTGRES_USER: dev, POSTGRES_PASSWORD: dev, POSTGRES_DB: appdb }
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dev"]
      interval: 5s
      retries: 5

  cache:
    image: redis:7-alpine

volumes: { node_modules: {}, postgres_data: {} }
```

**`Dockerfile.dev` — dev-optimized image with hot reload:**
```dockerfile
FROM node:20-alpine AS base
WORKDIR /workspace
COPY package*.json ./
RUN npm ci
COPY . .
EXPOSE 3000
CMD ["npm", "run", "dev"]  # nodemon/tsx watch for hot reload
```

Cross-reference: `container-kubernetes-patterns` — Production container patterns and health check standards.

---

### 3. Golden Path and Platform Engineering

A golden path is an opinionated, supported route for building a service — scaffolded templates, pre-wired CI, shared libraries, and self-service provisioning. An internal developer platform (IDP) makes the golden path the easiest path.

**Red Flags:**
- Every team copies CI YAML from a different source and diverges immediately
- Service templates are wikis, not executable scaffolds
- New services require a ticket to provision infrastructure
- No shared observability or auth library — each team re-implements

**Service template scaffold (TypeScript CLI):**
```typescript
import { execSync } from 'child_process';
import { mkdirSync, writeFileSync } from 'fs';
import { join } from 'path';

interface ServiceOptions { name: string; type: 'api' | 'worker' | 'cronjob'; team: string; }

function scaffoldService(opts: ServiceOptions): void {
  const serviceDir = join('services', opts.name);
  mkdirSync(serviceDir, { recursive: true });
  execSync(`cp -r templates/${opts.type}/. ${serviceDir}/`);
  writeFileSync(join(serviceDir, 'service.json'),
    JSON.stringify({ ...opts, createdAt: new Date().toISOString() }, null, 2));
}
```

**Golden path CI template (`templates/api/.github/workflows/ci.yml`):**
```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
jobs:
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run lint
      - run: npm run type-check
      - run: npm test -- --coverage
      - run: npm run build
      - uses: codecov/codecov-action@v4
```

**IDP service registration YAML (Backstage / Port compatible):**
```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: payment-service
  annotations:
    github.com/project-slug: acme/payment-service
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: checkout
  dependsOn: [component:order-service, resource:payments-db]
```

Cross-reference: `cicd-pipeline-patterns` — Reusable workflow patterns and pipeline templates.

---

### 4. Local-Prod Parity (Seed Scripts, Test Data Factories, Env Management)

Local-prod parity means the local development environment mirrors production data shapes, environment variables, and infrastructure configuration.

**Red Flags:**
- Production uses PostgreSQL; local uses SQLite — schema differences hide bugs
- Tests rely on manual database state that disappears after a restart
- `.env.example` is out of date and missing new required variables
- Data shapes in fixtures are stale compared to current schema

**TypeScript — test data factory with builder pattern:**
```typescript
import { faker } from '@faker-js/faker';

interface User { id: string; email: string; name: string; role: 'admin' | 'member'; createdAt: Date; }

// Spread overrides last — immutable, no mutation of defaults
const buildUser = (overrides: Partial<User> = {}): User => ({
  id: faker.string.uuid(), email: faker.internet.email(),
  name: faker.person.fullName(), role: 'member', createdAt: new Date(),
  ...overrides,
});
const buildAdminUser = (overrides: Partial<User> = {}) => buildUser({ role: 'admin', ...overrides });
```

**Seed script with idempotent upsert:**
```typescript
async function seed(): Promise<void> {
  // Idempotent: upsert avoids duplicate-key errors on re-runs
  await db.user.upsert({
    where: { email: 'admin@example.com' },
    update: {},
    create: { email: 'admin@example.com', name: 'Admin User', role: 'admin' },
  });
  await db.product.createMany({
    data: Array.from({ length: 20 }, (_, i) => ({ sku: `DEMO-${String(i+1).padStart(3,'0')}`, name: `Demo Product ${i+1}`, priceInCents: (i+1)*999, stock: 100 })),
    skipDuplicates: true,
  });
}
seed().catch(err => { console.error('Seed failed:', err); process.exit(1); }).finally(() => db.$disconnect());
```

**`.env.example` — comprehensive and documented:**
```bash
NODE_ENV=development
PORT=3000
DATABASE_URL=postgres://dev:dev@localhost:5432/appdb   # required
REDIS_URL=redis://localhost:6379                        # required
JWT_SECRET=change-me-in-production                      # generate: openssl rand -base64 32
STRIPE_SECRET_KEY=sk_test_...                           # optional — feature disabled when absent
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318       # optional
```

Cross-reference: `testing-patterns` — Test isolation and database reset strategies.

---

### 5. Fast Feedback Loops (Hot Reload, Incremental Builds, Test Watch Mode)

Fast feedback loops surface errors within seconds. The goal: a code change produces a visible result before the developer loses focus.

**Red Flags:**
- Full `tsc --build` on every save — takes 30+ seconds
- Test suite runs all 2000 tests on every file change
- Browser requires a manual refresh after a CSS change
- Docker rebuild triggered by a source-file edit (no volume mount)

**`package.json` — fast dev scripts:**
```json
{
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "test:watch": "vitest --watch",
    "test:related": "vitest related --watch",
    "type-check:watch": "tsc --noEmit --watch --preserveWatchOutput",
    "lint:fix": "eslint . --fix --cache",
    "build:incremental": "tsc --build --incremental"
  }
}
```

**Vitest configuration — fast incremental test runs:**
```typescript
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    changed: process.env.CI ? false : true,  // only changed files in dev
    pool: 'threads',
    poolOptions: { threads: { maxThreads: 4 } },
    reporter: ['verbose'],
    watchExclude: ['**/node_modules/**', '**/dist/**', '**/coverage/**'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      thresholds: { lines: 80, functions: 80 },
    },
  },
});
```

**`nodemon.json` — hot reload with selective watching:**
```json
{
  "watch": ["src"],
  "ext": "ts,json",
  "ignore": ["src/**/*.spec.ts", "dist/**"],
  "exec": "tsx src/index.ts",
  "delay": "250ms"
}
```

**Incremental TypeScript build cache in CI:**
```yaml
- uses: actions/cache@v4
  with:
    path: .tsbuildinfo
    key: tsbuildinfo-${{ hashFiles('tsconfig.json', 'src/**/*.ts') }}
    restore-keys: tsbuildinfo-
- run: npx tsc --noEmit --incremental
```

Cross-reference: `cicd-pipeline-patterns` — Caching layers and parallelism for CI speed.

---

### 6. DX-First API Design (Ergonomic SDKs, Descriptive Errors, Auto-Generated Docs)

An API is a developer interface. DX-first design means errors are actionable, SDKs match caller mental models, and documentation is generated from source rather than written separately.

**Red Flags:**
- Error responses return `{ "error": "Internal server error" }` with no code or guidance
- SDK methods require 7 positional arguments; callers must consult source
- API documentation is a wiki that lags the implementation by months
- Validation errors list field names but not what values are expected

**TypeScript — descriptive error response shape:**
```typescript
// Structured error: machine-readable code, human message, field details, requestId, docsUrl
interface ApiError {
  code: string; message: string;
  details?: Array<{ field: string; message: string; received?: unknown }>;
  requestId: string; docsUrl?: string;
}

function errorMiddleware(err: unknown, req: Request, res: Response, _next: NextFunction): void {
  const requestId = req.headers['x-request-id'] as string ?? crypto.randomUUID();

  if (err instanceof ValidationError) {
    res.status(422).json({
      code: 'VALIDATION_ERROR', message: 'Request validation failed',
      details: err.issues.map(i => ({ field: i.path.join('.'), message: i.message, received: i.received })),
      requestId, docsUrl: 'https://docs.example.com/errors#validation',
    } satisfies ApiError);
    return;
  }
  res.status(500).json({ code: 'INTERNAL_ERROR', message: 'An unexpected error occurred', requestId } satisfies ApiError);
}
```

**Ergonomic SDK — options object over positional arguments:**
```typescript
// BEFORE — seven positional args, caller must memorize order
async function createOrder(userId, items, currency, shippingAddressId, couponCode, idempotencyKey, notify)

// AFTER — single options object with sensible defaults
interface CreateOrderOptions {
  readonly userId: string;
  readonly items: ReadonlyArray<Item>;
  readonly currency?: string;          // defaults to 'USD'
  readonly shippingAddressId: string;
  readonly couponCode?: string;
  readonly idempotencyKey?: string;    // auto-generated if omitted
  readonly notify?: boolean;           // defaults to true
}

async function createOrder(opts: CreateOrderOptions): Promise<Order> {
  const options = { currency: 'USD', idempotencyKey: crypto.randomUUID(), notify: true, ...opts };
  // implementation
}
```

**OpenAPI auto-generation from Zod schemas:**
```typescript
import { z } from 'zod';
import { generateSchema } from '@anatine/zod-openapi';

const CreateOrderSchema = z.object({
  userId: z.string().uuid().describe('ID of the user placing the order'),
  items: z.array(z.object({
    sku: z.string().min(1),
    quantity: z.number().int().positive().max(999),
  })).min(1),
  currency: z.enum(['USD', 'EUR', 'GBP']).default('USD'),
});

export const createOrderOpenApiSchema = generateSchema(CreateOrderSchema);
// Register with openapi-backend — docs are always in sync with validation
```

Cross-reference: `api-rate-limiting-throttling` — Rate limit headers and error codes for 429 responses.

---

### 7. Developer Onboarding (Setup Scripts, Contributing Guides, ADRs)

Effective onboarding minimises time-to-first-PR. Setup scripts automate mechanical steps; contributing guides document conventions; ADRs preserve why decisions were made.

**Red Flags:**
- Setup instructions require 20 manual steps, some undocumented
- CONTRIBUTING.md was last updated three years ago
- New engineers discover conventions by reading existing code or asking colleagues
- No record of why the current technology choices were made

**Automated setup script (`scripts/setup.sh`) — key structure:**
```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Validate required tools and versions
for tool in node npm docker; do
  command -v "$tool" &>/dev/null || { echo "ERROR: $tool required" >&2; exit 1; }
done
[ "$(node --version | cut -d. -f1 | tr -d 'v')" -ge 20 ] || { echo "ERROR: Node 20+ required" >&2; exit 1; }
# 2. Install dependencies and copy env
npm ci
[ -f .env ] || cp .env.example .env
# 3. Start services, wait for health, migrate and seed
docker compose up -d db cache
until docker compose exec -T db pg_isready -U dev &>/dev/null; do sleep 1; done
npm run db:migrate && npm run db:seed

echo "Setup complete. Run 'npm run dev' to start."
```

**ADR template (`docs/adr/000-template.md`):**
```markdown
# ADR-NNN: <Title>

**Date:** YYYY-MM-DD
**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-NNN
**Deciders:** <names or teams>

## Context
What is the issue motivating this decision? What constraints or forces are in play?

## Decision
What was decided?

## Consequences
**Positive:** What becomes easier or possible?
**Negative:** What trade-offs or new problems does this introduce?

## Alternatives Considered
| Option | Reason Rejected |
|--------|----------------|
```

**CONTRIBUTING.md required sections:**
- Prerequisites (exact versions)
- Setup steps (link to setup.sh)
- Running tests (`npm test`, `npm run test:watch`)
- Branch naming (`feat/`, `fix/`, `chore/`)
- Commit message format (conventional commits)
- PR checklist (tests, lint, type-check)
- Code review expectations (SLA, required approvals)
- Architecture overview link / contact path

Cross-reference: `code-documentation-patterns` — JSDoc standards and inline documentation conventions.

---

### 8. DX Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Works on My Machine** | Local setup differs per developer; no reproducible environment | Adopt dev containers; automate setup with `setup.sh` |
| **30-Minute Build** | Every change triggers a full rebuild of all packages | Use affected builds (Nx/Turborepo) with remote cache |
| **Undocumented Tribal Knowledge** | Critical setup steps exist only in colleagues' heads | Document in CONTRIBUTING.md; automate in setup scripts |
| **Manual Environment Setup** | Developers manually install tools and configure env vars | Dev containers + `.env.example` with setup validation |
| **Test-Data Desert** | Tests fail because required seed data is missing | Idempotent seed scripts; test-data factories per test |
| **Stale Docs** | README and API docs lag implementation by months | Generate docs from source (OpenAPI, TypeDoc) |
| **Monolith CI on Monorepo** | All tests run on every commit regardless of what changed | Affected build detection; per-package CI pipelines |
| **Magic Environment Variables** | Required env vars discovered at runtime, not documented | `.env.example` with comments; startup validation |

**Magic environment variables — startup validation fix:**
```typescript
import { z } from 'zod';

const EnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']),
  PORT: z.coerce.number().int().min(1024).max(65535).default(3000),
  DATABASE_URL: z.string().url(),
  REDIS_URL: z.string().url(),
  JWT_SECRET: z.string().min(32, 'JWT_SECRET must be at least 32 characters'),
  STRIPE_SECRET_KEY: z.string().optional(),
});

// Fail at startup — not at the first request that needs the value
const parseResult = EnvSchema.safeParse(process.env);
if (!parseResult.success) {
  console.error('Invalid environment configuration:');
  parseResult.error.issues.forEach(issue => console.error(`  ${issue.path.join('.')}: ${issue.message}`));
  process.exit(1);
}

export const config = parseResult.data;
```

---

## DX Metrics Worth Tracking

| Metric | Target | Why It Matters |
|--------|--------|----------------|
| Time-to-first-PR (new hire) | < 1 day | Measures onboarding friction |
| Local build time (cold) | < 3 minutes | Affects daily developer cadence |
| Local build time (incremental) | < 30 seconds | Determines hot-path loop speed |
| Test suite time (watch mode) | < 10 seconds for related tests | Keeps TDD flow viable |
| CI pipeline time (PR check) | < 10 minutes | Controls PR review velocity |
| Number of manual setup steps | 0 (fully scripted) | Each manual step is a potential blocker |

---

## Cross-References

- `cicd-pipeline-patterns` — Pipeline caching, parallelism, affected-build integration in CI
- `code-documentation-patterns` — Auto-generated docs from types, JSDoc standards, ADR workflows
- `testing-patterns` — Test isolation, data factories, watch-mode configuration, coverage gates
- `container-kubernetes-patterns` — Production container patterns that dev containers should mirror
- `observability-patterns` — Local observability setup (OTEL collector in docker-compose.dev.yml)
