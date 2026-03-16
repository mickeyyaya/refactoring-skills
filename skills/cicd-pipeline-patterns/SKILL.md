---
name: cicd-pipeline-patterns
description: Use when designing or reviewing CI/CD pipelines — covers pipeline design (stages, jobs, parallelism), GitOps and IaC patterns, build optimization (caching, incremental builds, artifact management), deployment strategies (blue-green, canary, rolling update, recreate), security in pipelines (SLSA, SBOM, supply chain, secrets management), testing in pipelines (shift-left, test pyramid, flaky test management), pipeline anti-patterns, and rollback/disaster recovery
---

# CI/CD Pipeline Patterns

## Overview

Slow pipelines block delivery, misconfigured secrets become attack vectors, and poorly designed deployment strategies cause downtime. Use this guide when designing, reviewing, or improving CI/CD pipelines across GitHub Actions, GitLab CI, and general pipeline tooling.

**When to use:** Designing a new pipeline from scratch; reviewing an existing pipeline for speed or reliability; evaluating deployment strategies for a release; hardening supply chain security; investigating flaky builds or slow test suites.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Pipeline Design | Stages, jobs, fan-out/fan-in with explicit dependencies | All jobs sequential, one massive job doing everything |
| GitOps / IaC | Git is the single source of truth for infra and config | Manual kubectl apply, config drift between environments |
| Build Optimization | Cache dependencies, reuse artifacts, skip unchanged work | `npm install` from scratch on every run, no layer caching |
| Blue-Green Deployment | Two identical envs; route traffic atomically | Deploy in place with downtime, no rollback path |
| Canary Deployment | Gradually shift traffic to new version | All-or-nothing deploy with no traffic splitting |
| Rolling Update | Replace instances incrementally, keep service alive | Recreate all pods at once, causing downtime |
| SLSA / SBOM | Provenance and software bill of materials for supply chain | No artifact signing, no dependency audit |
| Shift-Left Testing | Run tests as early and often as possible | Integration tests only, no unit tests in pipeline |
| Flaky Test Management | Quarantine and track unstable tests, never ignore them | Retrying flaky tests silently, masking real failures |
| Rollback & DR | Automated rollback triggers, tested recovery procedures | Manual rollback, untested restore procedures |

---

## Patterns in Detail

### 1. Pipeline Design — Stages, Jobs, and Parallelism

Well-structured pipelines define explicit stages (lint, test, build, deploy) with dependency graphs that maximize parallelism. Each job should do exactly one thing and produce a clear artifact or signal.

**Red Flags:**
- Single job that lints, tests, builds, and deploys in sequence
- No dependency graph — all jobs run sequentially by default
- Jobs downloading the same dependency multiple times
- No timeout per job — a hanging test blocks the whole pipeline
- Missing `needs` / `depends_on` declarations — implicit ordering assumptions

**GitHub Actions — parallel jobs with fan-in:**
```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main, "release/**"]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm run lint

  unit-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci
      - run: npm test -- --coverage
      - uses: actions/upload-artifact@v4
        with:
          name: coverage-report
          path: coverage/

  build:
    needs: [lint, unit-test]   # fan-in: only run after both pass
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci && npm run build
      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/

  deploy-staging:
    needs: build
    environment: staging
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: dist, path: dist/ }
      - run: ./scripts/deploy.sh staging
```

**GitLab CI — stages with parallel matrix:**
```yaml
# .gitlab-ci.yml
stages: [lint, test, build, deploy]

default:
  image: node:20-alpine
  cache:
    key: "$CI_COMMIT_REF_SLUG"
    paths: [node_modules/]

lint:
  stage: lint
  script: [npm ci, npm run lint]

test:unit:
  stage: test
  script: [npm ci, npm test -- --coverage]
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage/cobertura-coverage.xml

test:e2e:
  stage: test
  parallel:
    matrix:
      - BROWSER: [chrome, firefox, webkit]
  script: [npm ci, npx playwright test --project=$BROWSER]

build:
  stage: build
  needs: [lint, test:unit]
  script: [npm ci, npm run build]
  artifacts:
    paths: [dist/]
    expire_in: 1 day

deploy:staging:
  stage: deploy
  needs: [build]
  environment: staging
  script: [./scripts/deploy.sh staging]
  only: [main]
```

---

### 2. GitOps and Infrastructure as Code

GitOps treats Git as the single source of truth. Every change to infrastructure or configuration is expressed as a pull request, reviewed, and reconciled automatically by an operator (Argo CD, Flux). Manual `kubectl apply` or console changes create drift and are immediately overwritten by the reconciler.

**Red Flags:**
- Config applied manually; Git repo does not reflect live state
- Infrastructure defined only in runbooks, not in code
- Separate processes for app deployment and infra provisioning (no single pane)
- No drift detection — live state can diverge from declared state
- Secrets stored in Git as plaintext instead of sealed/external secrets

**Argo CD application manifest:**
```yaml
# k8s/argocd/app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/my-app-config
    targetRevision: HEAD
    path: k8s/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true      # remove resources deleted from Git
      selfHeal: true   # revert manual changes automatically
    syncOptions:
      - CreateNamespace=true
```

**Terraform pipeline pattern (GitHub Actions):**
```yaml
# .github/workflows/terraform.yml
jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - name: Terraform Init
        run: terraform init
        env:
          TF_VAR_environment: staging
      - name: Terraform Plan
        id: plan
        run: terraform plan -out=tfplan -no-color
      - name: Upload plan
        uses: actions/upload-artifact@v4
        with: { name: tfplan, path: tfplan }

  apply:
    needs: plan
    environment: production   # requires manual approval
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: tfplan }
      - run: terraform apply tfplan
```

Cross-reference: `feature-flags-progressive-delivery` — progressive rollouts via GitOps-managed flag configs.

---

### 3. Build Optimization — Caching, Incremental Builds, Artifact Management

Every minute shaved from a pipeline is a minute developers spend on code instead of waiting. The three levers are: dependency caching (avoid re-downloading), layer/build caching (avoid re-compiling unchanged code), and artifact reuse (avoid re-building what already passed).

**Red Flags:**
- `npm install` / `pip install` / `go mod download` on every run with no cache
- Docker image rebuilt from `FROM` on every commit because no layer caching
- Test artifacts not uploaded — downstream jobs re-run tests already passed
- Build matrix with no cache key scoping — one branch pollutes another's cache
- Artifacts with no expiry — storage cost grows unbounded

**Dependency caching (GitHub Actions):**
```yaml
- uses: actions/setup-node@v4
  with:
    node-version: 20
    cache: npm           # built-in: caches ~/.npm keyed by package-lock.json hash

# For monorepos — scope cache key to workspace
- uses: actions/cache@v4
  with:
    path: |
      ~/.npm
      apps/api/node_modules
      apps/web/node_modules
    key: ${{ runner.os }}-npm-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-npm-
```

**Docker layer caching with BuildKit:**
```yaml
- name: Build and push
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    tags: ghcr.io/org/app:${{ github.sha }}
    cache-from: type=registry,ref=ghcr.io/org/app:buildcache
    cache-to: type=registry,ref=ghcr.io/org/app:buildcache,mode=max
```

**Incremental build script (bash, skip unchanged packages):**
```bash
#!/usr/bin/env bash
# scripts/build-changed.sh — build only packages changed since base branch
set -euo pipefail

BASE=${BASE_BRANCH:-origin/main}
CHANGED=$(git diff --name-only "$BASE"...HEAD | xargs -I{} dirname {} | sort -u)

for PKG in packages/*/; do
  PKG_NAME=$(basename "$PKG")
  if echo "$CHANGED" | grep -q "^packages/$PKG_NAME"; then
    echo "Building $PKG_NAME (changed)"
    npm run build --workspace="$PKG"
  else
    echo "Skipping $PKG_NAME (unchanged)"
  fi
done
```

---

### 4. Deployment Strategies

The right deployment strategy depends on your tolerance for downtime, traffic splitting capability, and rollback speed requirements.

**Red Flags:**
- Recreate strategy on a production service with no maintenance window
- Blue-green deployed but old (blue) environment torn down immediately — no rollback window
- Canary with no metrics gate — traffic shifted based on time, not signal
- Rolling update with `maxUnavailable: 100%` — equivalent to recreate
- No smoke test after deploy before serving traffic

**Blue-Green Deployment (GitHub Actions + AWS ALB):**
```yaml
deploy-blue-green:
  runs-on: ubuntu-latest
  steps:
    - name: Deploy to Green
      run: |
        aws ecs update-service \
          --cluster prod \
          --service my-app-green \
          --force-new-deployment

    - name: Wait for Green to stabilize
      run: |
        aws ecs wait services-stable \
          --cluster prod \
          --services my-app-green

    - name: Smoke test Green
      run: curl --fail https://green.internal.example.com/health

    - name: Shift traffic to Green
      run: |
        aws elbv2 modify-listener \
          --listener-arn "$LISTENER_ARN" \
          --default-actions Type=forward,TargetGroupArn="$GREEN_TG_ARN"

    - name: Keep Blue running for 30 min (rollback window)
      run: echo "Blue stays alive; tear down in post-deploy job"
```

**Canary Deployment (Kubernetes + Argo Rollouts):**
```yaml
# k8s/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-app
spec:
  replicas: 10
  strategy:
    canary:
      steps:
        - setWeight: 10      # send 10% traffic to canary
        - pause: { duration: 5m }
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 100
      canaryService: my-app-canary
      stableService: my-app-stable
```

**Rolling Update (Kubernetes):**
```yaml
# Deployment spec — safe rolling update defaults
spec:
  replicas: 6
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2          # allow 2 extra pods during rollout
      maxUnavailable: 0    # never take a pod down before new one is ready
  template:
    spec:
      containers:
        - name: app
          readinessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 5
            periodSeconds: 5
```

Cross-reference: `feature-flags-progressive-delivery` — combine canary with feature flags for traffic splitting at the application layer without separate infra.

---

### 5. Security in Pipelines — SLSA, SBOM, Supply Chain, Secrets Management

**Red Flags:**
- Secrets stored in repository or build logs
- Third-party actions pinned to a mutable tag (`@v3`) instead of a commit SHA
- No artifact signing — anyone could inject a tampered artifact
- No dependency audit — known-vulnerable packages ship to production
- Pipeline permissions are `permissions: write-all` by default
- No SBOM generated — no visibility into what is in the deployed artifact

**Least-privilege permissions (GitHub Actions):**
```yaml
permissions:
  contents: read       # default: read only
  packages: write      # only the job that pushes images gets write

jobs:
  build:
    permissions:
      contents: read
      id-token: write  # for OIDC token only
```

**Pin third-party actions to SHA:**
```yaml
# WRONG — mutable tag, supply chain risk
- uses: actions/checkout@v4

# CORRECT — immutable SHA
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
```

**SBOM generation and artifact signing (cosign + syft):**
```yaml
- name: Generate SBOM
  uses: anchore/sbom-action@v0
  with:
    image: ghcr.io/org/app:${{ github.sha }}
    artifact-name: sbom.spdx.json
    output-file: sbom.spdx.json

- name: Sign image with cosign (OIDC keyless)
  run: |
    cosign sign --yes ghcr.io/org/app:${{ github.sha }}

- name: Attest SBOM
  run: |
    cosign attest --yes \
      --predicate sbom.spdx.json \
      --type spdxjson \
      ghcr.io/org/app:${{ github.sha }}
```

**Secrets management — never in env plaintext:**
```yaml
# Use OIDC for cloud provider auth (no long-lived credentials)
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/github-actions-deploy
    aws-region: us-east-1

# Reference secrets from vault, not repo secrets where possible
- name: Fetch secrets from Vault
  uses: hashicorp/vault-action@v3
  with:
    url: https://vault.example.com
    method: jwt
    path: jwt/github
    secrets: |
      secret/data/prod/db DB_PASSWORD | DB_PASSWORD ;
      secret/data/prod/api API_KEY | API_KEY
```

**Dependency audit in pipeline:**
```bash
#!/usr/bin/env bash
# scripts/audit-deps.sh
set -euo pipefail

echo "=== npm audit ==="
npm audit --audit-level=high

echo "=== License check ==="
npx license-checker --onlyAllow "MIT;Apache-2.0;BSD-2-Clause;BSD-3-Clause;ISC"

echo "=== Trivy container scan ==="
trivy image --exit-code 1 --severity HIGH,CRITICAL \
  "ghcr.io/org/app:${IMAGE_TAG}"
```

Cross-reference: `security-patterns-code-review` — SAST, secrets detection, and dependency vulnerability patterns for code review.

---

### 6. Testing in Pipelines — Shift-Left, Test Pyramid, Flaky Test Management

**Red Flags:**
- Only integration or E2E tests in CI — slow feedback, hard to isolate failures
- E2E tests run on every commit to every branch — unnecessary cost and time
- Flaky tests retried silently — masking intermittent failures in production code
- No coverage threshold enforced — coverage regresses unnoticed
- Tests that require a live database on the unit test stage

**Shift-left — test pyramid in CI:**

The test pyramid applied to pipeline stages:

```
         /\
        /E2E\         — run on main/release branches only (slow, costly)
       /------\
      /Integr. \      — run on PRs, keyed to changed services
     /----------\
    / Unit Tests  \   — run on every commit, every branch (fast, cheap)
   /--------------\
```

**Unit tests — fast, isolated, no external deps:**
```yaml
# GitHub Actions — unit tests with coverage gate
unit-test:
  runs-on: ubuntu-latest
  timeout-minutes: 10
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-node@v4
      with: { node-version: 20, cache: npm }
    - run: npm ci
    - run: npm test -- --coverage --coverageThreshold='{"global":{"lines":80}}'
```

**Integration tests — service dependencies via Docker Compose:**
```yaml
# GitLab CI — integration test with real DB
test:integration:
  stage: test
  services:
    - name: postgres:16-alpine
      alias: db
  variables:
    POSTGRES_DB: testdb
    POSTGRES_USER: test
    POSTGRES_PASSWORD: test
    DATABASE_URL: postgres://test:test@db:5432/testdb
  script:
    - npm ci
    - npm run db:migrate
    - npm run test:integration
```

**Flaky test management — quarantine pattern:**
```bash
#!/usr/bin/env bash
# scripts/run-tests-with-quarantine.sh
# Tests tagged @flaky are run but their failure does not fail the build.
# Failures are reported to a tracking dashboard for investigation.
set -euo pipefail

# Run stable tests — any failure fails the build
npx jest --testPathIgnorePatterns=".*\\.flaky\\.test\\.ts" --ci

# Run quarantined flaky tests — collect results but do not fail
npx jest --testPathPattern=".*\\.flaky\\.test\\.ts" --ci || {
  echo "FLAKY_FAILURES=true" >> "$GITHUB_ENV"
  # Post to tracking system
  curl -s -X POST "$FLAKY_TRACKER_URL" \
    -H "Content-Type: application/json" \
    -d "{\"branch\": \"$GITHUB_REF_NAME\", \"run\": \"$GITHUB_RUN_ID\"}"
}
```

**Playwright E2E — run only on main, retry on failure:**
```yaml
# .github/workflows/e2e.yml
e2e:
  runs-on: ubuntu-latest
  if: github.ref == 'refs/heads/main'
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-node@v4
      with: { node-version: 20, cache: npm }
    - run: npm ci && npx playwright install --with-deps
    - name: Run E2E tests
      run: npx playwright test --retries=2   # retry once for genuine flakes
    - uses: actions/upload-artifact@v4
      if: failure()
      with:
        name: playwright-report
        path: playwright-report/
```

Cross-reference: `testing-patterns` — unit, integration, and E2E test structure patterns; contract testing for microservices.

---

### 7. Pipeline Anti-Patterns

| Anti-Pattern | Description | Fix |
|-------------|-------------|-----|
| **Long-Running Pipeline** | Single pipeline takes >30 min; developer context-switches away | Split into fast (lint/unit) and slow (E2E) tiers; fast tier on every commit |
| **Snowflake Configuration** | Each service has its own hand-crafted pipeline; no reuse | Extract reusable workflow templates or shared GitLab CI includes |
| **Manual Gates Everywhere** | Every stage requires a human approval; deployment bottleneck | Automate quality gates with metrics; manual approval only at prod boundary |
| **Mutable Artifacts** | Same artifact tag overwritten on every build | Tag artifacts with commit SHA; treat tags as immutable |
| **God Job** | One job lints, tests, builds, scans, and deploys | Single responsibility per job; explicit `needs` graph |
| **No Timeout** | Jobs hang indefinitely on network or test failures | Set `timeout-minutes` on every job |
| **Secret in Logs** | `echo $SECRET_TOKEN` prints secrets to build log | Never echo secrets; use `::add-mask::` if unavoidable |
| **Test After Build** | Tests run only after a slow Docker build | Run unit tests before the build; fail fast on code issues |
| **Pipeline as Documentation** | Complex logic buried in YAML; hard to test locally | Extract logic into scripts; keep YAML as thin orchestration |

**Snowflake config — before and after:**

```yaml
# BEFORE — every service has its own test job definition
test-api:
  runs-on: ubuntu-latest
  steps:
    - run: npm ci && npm test

test-worker:
  runs-on: ubuntu-latest
  steps:
    - run: npm ci && npm test

# AFTER — reusable workflow called by each service
# .github/workflows/node-test.yml (reusable)
on:
  workflow_call:
    inputs:
      working-directory:
        type: string
        required: true
jobs:
  test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ inputs.working-directory }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20, cache: npm }
      - run: npm ci && npm test

# Calling workflow
jobs:
  test-api:
    uses: ./.github/workflows/node-test.yml
    with:
      working-directory: apps/api
  test-worker:
    uses: ./.github/workflows/node-test.yml
    with:
      working-directory: apps/worker
```

---

### 8. Rollback and Disaster Recovery

Deployments fail. The difference between a 5-minute incident and a 2-hour outage is whether rollback is automated and rehearsed.

**Red Flags:**
- Rollback procedure is a runbook that requires manual steps under pressure
- Database migrations applied before new code deployed — migration not backward-compatible
- Old container images deleted immediately after deploy — cannot roll back quickly
- Rollback never tested in staging — procedure fails when needed most
- No automatic rollback trigger based on error rate or health check

**Automated rollback on health check failure:**
```bash
#!/usr/bin/env bash
# scripts/deploy-with-rollback.sh
set -euo pipefail

PREVIOUS_REVISION=$(kubectl rollout history deployment/my-app | tail -2 | head -1 | awk '{print $1}')

echo "Deploying revision from image: $IMAGE_TAG"
kubectl set image deployment/my-app app="ghcr.io/org/app:$IMAGE_TAG"
kubectl rollout status deployment/my-app --timeout=5m || {
  echo "Rollout failed — reverting to revision $PREVIOUS_REVISION"
  kubectl rollout undo deployment/my-app --to-revision="$PREVIOUS_REVISION"
  kubectl rollout status deployment/my-app --timeout=5m
  exit 1
}

# Post-deploy smoke test
echo "Running smoke test..."
sleep 5
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://api.example.com/health)
if [ "$HEALTH" != "200" ]; then
  echo "Smoke test failed (HTTP $HEALTH) — reverting"
  kubectl rollout undo deployment/my-app
  exit 1
fi
echo "Deploy successful"
```

**Backward-compatible migration pattern:**
```bash
# RULE: migrations must be backward-compatible with N-1 version of the app.
# Deploy order: migrate → deploy new app → (optional) cleanup migration

# Phase 1: Add nullable column (safe — old code ignores it)
ALTER TABLE users ADD COLUMN display_name VARCHAR(255);

# Deploy new app code (reads display_name, falls back to name if null)

# Phase 2: Backfill (run as a job, not during deploy)
UPDATE users SET display_name = name WHERE display_name IS NULL;

# Phase 3: Add NOT NULL constraint (only after all rows backfilled)
ALTER TABLE users ALTER COLUMN display_name SET NOT NULL;
```

**Disaster recovery — pipeline for DB restore:**
```yaml
# .github/workflows/dr-restore.yml
name: DR - Restore Database
on:
  workflow_dispatch:
    inputs:
      snapshot_id:
        description: RDS snapshot identifier
        required: true
      environment:
        description: Target environment
        type: choice
        options: [staging, production]

jobs:
  restore:
    environment: ${{ inputs.environment }}  # requires manual approval
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DR_ROLE_ARN }}
          aws-region: us-east-1
      - name: Restore RDS snapshot
        run: |
          aws rds restore-db-instance-from-db-snapshot \
            --db-instance-identifier "restored-${{ inputs.environment }}-$(date +%s)" \
            --db-snapshot-identifier "${{ inputs.snapshot_id }}"
      - name: Verify restore
        run: ./scripts/verify-db-restore.sh
```

**Regular DR drill (scheduled):**
```yaml
# .github/workflows/dr-drill.yml
on:
  schedule:
    - cron: "0 2 * * 0"   # weekly, Sunday 2 AM UTC

jobs:
  restore-drill:
    runs-on: ubuntu-latest
    steps:
      - name: Restore latest snapshot to staging
        run: ./scripts/dr-drill.sh staging
      - name: Run acceptance tests against restored DB
        run: npm run test:smoke -- --env=staging-restored
      - name: Report drill results
        if: always()
        run: ./scripts/report-dr-results.sh
```

---

## Pipeline Anti-Pattern Red Flags Summary

```bash
# Quick pipeline health check (run from repo root)
#!/usr/bin/env bash
set -euo pipefail

FAIL=0

check() {
  local msg="$1"; shift
  if "$@" > /dev/null 2>&1; then
    echo "PASS: $msg"
  else
    echo "FAIL: $msg"
    FAIL=1
  fi
}

# Check for pinned SHA on third-party actions
check "Actions pinned to SHA" \
  grep -rqE "uses: [a-z-]+/[a-z-]+@[0-9a-f]{40}" .github/workflows/

# Check for timeout-minutes on all jobs
check "All jobs have timeout" \
  ! grep -rL "timeout-minutes" .github/workflows/*.yml

# Check for explicit permissions block
check "Permissions explicitly set" \
  grep -rq "^permissions:" .github/workflows/

exit $FAIL
```

---

## Cross-References

- `feature-flags-progressive-delivery` — canary and progressive rollouts at the application layer; combine with pipeline-level deployment strategies
- `security-patterns-code-review` — SAST, secrets scanning, and dependency auditing patterns for pipeline security gates
- `testing-patterns` — unit, integration, and contract test structure; shift-left testing strategy and coverage requirements
- `observability-patterns` — instrumenting deploy events; correlating deployments with error rate spikes for automated rollback triggers
- `microservices-resilience-patterns` — blue-green and canary at the service mesh layer (Istio traffic splitting)
