---
name: container-kubernetes-patterns
description: Use when designing, reviewing, or debugging Kubernetes workloads — covers health probe design, resource requests vs limits, autoscaling (HPA/KEDA/VPA), PodDisruptionBudget and graceful shutdown, workload RBAC isolation, configuration injection, and container anti-patterns (CrashLoopBackOff, OOMKilled, Pending, fat images, root containers)
---

# Container and Kubernetes Patterns

## Overview

Misconfigured probes cause unnecessary restarts. Missing resource limits allow noisy-neighbor OOMKills. Secrets baked into images become permanent liabilities. Use this guide during workload design and code review to catch Kubernetes configuration hazards before they reach production.

**When to use:** Designing new Kubernetes workloads; reviewing Deployment, StatefulSet, or Job manifests; debugging CrashLoopBackOff, OOMKilled, or Pending pods; hardening workload security posture; evaluating autoscaling strategies.

## Quick Reference

| Pattern | Core Idea | Primary Red Flag |
|---------|-----------|-----------------|
| Health Probes | Signal container readiness and liveness to the control plane | Missing readinessProbe, liveness probe too sensitive, no startupProbe for slow init |
| Resource Requests/Limits | Requests for scheduling, limits for protection | No requests (random scheduling), no limits (OOMKill risk), limits == requests (throttling) |
| HPA / KEDA / VPA | Scale pods or nodes based on metrics | Static replicas in production, HPA + VPA CPU conflict, no scale-down stabilization |
| PodDisruptionBudget | Guarantee minimum availability during voluntary disruptions | No PDB on critical workloads, SIGTERM not handled, preStop hook missing |
| RBAC Isolation | Least-privilege ServiceAccount per workload | Default service account, wildcard RBAC rules, cross-namespace token mounts |
| Configuration Injection | ConfigMap and Secret via env or volume | Secrets baked into images, plaintext secrets in ConfigMaps, no secret rotation path |
| Anti-Patterns | Common failure modes | CrashLoopBackOff, fat images, root containers, host-path mounts |

---

## Patterns in Detail

### 1. Health Probe Design

Kubernetes uses three probe types to manage container lifecycle. Choosing the wrong thresholds is the most common source of unnecessary restarts and traffic drops.

**Probe Types:**
- **livenessProbe** — restarts container on failure. Internal state only; never check external deps.
- **readinessProbe** — removes pod from Service endpoints. Check all deps needed to serve traffic.
- **startupProbe** — disables liveness/readiness until it passes. Required for slow-starting containers.

**Red Flags:**
- No `readinessProbe` — pod receives traffic before it is ready, causing request errors at deploy time
- `livenessProbe` checks an external database — one DB blip restarts all pods simultaneously
- `livenessProbe` and `readinessProbe` use the same endpoint — cannot distinguish "unhealthy" from "not ready"
- No `startupProbe` for slow-starting containers — liveness kicks in and CrashLoopBackOff begins
- `failureThreshold: 1` on liveness — one transient hiccup restarts the container
- `initialDelaySeconds` as a substitute for `startupProbe` — fragile; fixed delay is too short on slow nodes, too long on fast ones

**YAML — correct three-probe setup:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
spec:
  template:
    spec:
      containers:
        - name: api
          image: myapp:1.2.3
          ports:
            - containerPort: 8080
          startupProbe:
            httpGet:
              path: /healthz/startup
              port: 8080
            failureThreshold: 30   # 30 * 10s = 5 min max startup time
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz/ready  # checks DB connection, cache, upstreams
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
            successThreshold: 1
          livenessProbe:
            httpGet:
              path: /healthz/live   # only checks internal state, no external deps
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
```

**TypeScript — separate liveness vs readiness endpoints:**
```typescript
import express from 'express';

const app = express();
let dbReady = false;

// Liveness: internal state only — never check external dependencies here
app.get('/healthz/live', (_req, res) => {
  res.status(200).json({ status: 'alive' });
});

// Readiness: checks all dependencies needed to serve traffic
app.get('/healthz/ready', async (_req, res) => {
  try {
    await db.ping();
    res.status(200).json({ status: 'ready' });
  } catch (err) {
    res.status(503).json({ status: 'not ready', reason: 'db unreachable' });
  }
});

// Startup: called by startupProbe until initialization completes
app.get('/healthz/startup', (_req, res) => {
  if (dbReady) {
    res.status(200).json({ status: 'started' });
  } else {
    res.status(503).json({ status: 'starting' });
  }
});
```

---

### 2. Resource Requests vs Limits

Requests and limits serve different purposes. Conflating them leads to either poor bin-packing or runtime instability.

**Concepts:**
- **requests** — used by the scheduler; container is guaranteed at least this much.
- **limits** — enforced by kernel cgroup at runtime. CPU limit causes throttling; memory limit causes OOMKill.

**Red Flags:**
- No `requests` set — scheduler places pods randomly; node overcommit causes evictions
- No `limits` set — one container can consume all node memory, OOMKilling neighbors
- `limits.cpu` == `requests.cpu` — Guaranteed QoS class, but also means any CPU burst is throttled immediately; prefer a ratio of 2–4x for bursty workloads
- `limits.memory` << actual peak usage — container OOMKilled on every traffic spike
- Setting CPU limits on latency-sensitive services — Linux CFS throttling adds p99 latency spikes

**YAML — recommended resource configuration:**
```yaml
resources:
  requests:
    cpu: "250m"       # scheduler sees this; fits 4 pods per 1 CPU core
    memory: "256Mi"   # must reflect actual steady-state usage
  limits:
    cpu: "1000m"      # allow 4x burst; remove entirely for latency-critical services
    memory: "512Mi"   # set to p99 peak + 20% buffer to avoid OOMKill
```

**QoS Classes:**
| Class | Condition | Eviction Priority |
|-------|-----------|------------------|
| Guaranteed | requests == limits for all containers | Evicted last |
| Burstable | requests < limits, or partial spec | Middle priority |
| BestEffort | No requests or limits | Evicted first |

Cross-reference: `observability-patterns` — set up memory usage alerts at 80% of the limit to proactively catch OOMKill risk before it occurs.

---

### 3. Autoscaling: HPA, KEDA, and VPA

**HPA** scales replica count on CPU/memory/custom metrics. **KEDA** extends HPA with event-driven triggers (queue depth, Kafka lag, cron). **VPA** adjusts resource requests/limits per pod.

**Red Flags:**
- Static `replicas` in production Deployment manifest — prevents HPA from taking effect (HPA will override, but static value causes confusion)
- HPA and VPA both targeting CPU — they conflict; use VPA in `Off` or `Initial` mode when HPA manages CPU
- No `scaleDown.stabilizationWindowSeconds` — flapping between scale-up and scale-down events
- KEDA trigger threshold too low — scale-up on every queue message; too high — backlog builds before scaling
- No `minReplicas: 2` — single replica means zero availability during scale-down or node drain

**YAML — HPA with stabilization window:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-server-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-server
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60   # scale up when avg CPU > 60%
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # wait 5 min before scaling down
      policies:
        - type: Pods
          value: 2
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 30
```

**YAML — KEDA ScaledObject for queue-based scaling:**
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-scaledobject
spec:
  scaleTargetRef:
    name: worker-deployment
  minReplicaCount: 1
  maxReplicaCount: 50
  cooldownPeriod: 120
  triggers:
    - type: aws-sqs-queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123/my-queue
        queueLength: "10"        # target: 10 messages per replica
        awsRegion: us-east-1
```

**HPA vs KEDA vs VPA decision matrix:**
| Scenario | Recommended |
|----------|------------|
| Stateless service, CPU-driven | HPA |
| Message consumer, queue-driven | KEDA |
| Right-sizing requests after observing real usage | VPA (recommendation mode) |
| Batch job, schedule-based | KEDA cron trigger |
| Avoid HPA+VPA CPU conflict | HPA for replicas, VPA `Off` for resource tuning |

---

### 4. PodDisruptionBudget and Graceful Shutdown

Voluntary disruptions must not drop in-flight requests. PDB prevents too many pods going down at once; SIGTERM handling drains connections before exit.

**Red Flags:**
- No `PodDisruptionBudget` on critical Deployments — `kubectl drain` removes all pods simultaneously
- `minAvailable: 0` or `maxUnavailable: 100%` PDB — does not protect against simultaneous removal
- Container does not handle SIGTERM — kubelet sends SIGTERM, waits `terminationGracePeriodSeconds`, then sends SIGKILL; unhandled SIGTERM means abrupt kill
- No `preStop` hook and service endpoint removal not accounted for — pod removed from endpoints but new requests still arrive for a few seconds
- `terminationGracePeriodSeconds` shorter than in-flight request timeout

**YAML — PodDisruptionBudget:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-server-pdb
spec:
  minAvailable: 2          # or use maxUnavailable: 1
  selector:
    matchLabels:
      app: api-server
```

**YAML — preStop hook to delay SIGTERM:**
```yaml
lifecycle:
  preStop:
    exec:
      command: ["sh", "-c", "sleep 5"]   # allow endpoint propagation before shutdown
terminationGracePeriodSeconds: 60
```

**TypeScript — graceful shutdown with SIGTERM:**
```typescript
import http from 'http';

const server = http.createServer(app);

function shutdown(): void {
  server.close(async (err) => {
    if (err) { console.error('Shutdown error:', err); process.exit(1); }
    try { await db.close(); process.exit(0); }
    catch (dbErr) { console.error('DB close failed:', dbErr); process.exit(1); }
  });
  // Force exit if graceful shutdown exceeds terminationGracePeriodSeconds
  setTimeout(() => process.exit(1), 50_000).unref();
}

process.on('SIGTERM', shutdown);
process.on('SIGINT',  shutdown);
server.listen(8080);
```

Cross-reference: `cicd-pipeline-patterns` — rolling update strategy and `maxUnavailable`/`maxSurge` settings pair directly with PDB to control blast radius during deploys.

---

### 5. Workload RBAC Isolation

Every pod runs as a ServiceAccount. Without explicit restriction, pods access the Kubernetes API with broad default permissions. NetworkPolicy limits pod-to-pod traffic.

**Red Flags:**
- Pod uses `default` ServiceAccount — shares permissions with every other workload in the namespace
- ServiceAccount has `cluster-admin` or wildcard `verbs: ["*"]` rules — blast radius of a compromised pod is the entire cluster
- No `automountServiceAccountToken: false` for workloads that do not call the Kubernetes API
- No `NetworkPolicy` — any pod can reach any other pod across namespaces
- NetworkPolicy with empty `podSelector: {}` — blocks all ingress/egress, misconfigured deny-all

**YAML — minimal RBAC setup:**
```yaml
# ServiceAccount — one per workload
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-server-sa
  namespace: production
automountServiceAccountToken: false   # disable unless pod calls K8s API
---
# Role — only what this workload actually needs
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-server-role
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["api-server-config"]   # restrict to named resource
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-server-rolebinding
  namespace: production
subjects:
  - kind: ServiceAccount
    name: api-server-sa
    namespace: production
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: api-server-role
# In Deployment: spec.template.spec.serviceAccountName: api-server-sa
```

**YAML — NetworkPolicy for micro-segmentation:**
```yaml
# Default deny-all ingress/egress for namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
# Allow api-server to receive traffic from ingress controller only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-server-allow-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api-server
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
    - ports:
        - port: 53    # allow DNS
          protocol: UDP
```

Cross-reference: `security-patterns-code-review` — token scoping, short-lived credentials, and secret scanning complement K8s RBAC.

---

### 6. Configuration Injection

Secrets must never be baked into images. ConfigMaps hold non-sensitive config; Secrets hold credentials. Both are injected at runtime via env vars or volume mounts.

**Red Flags:**
- Secret value hardcoded in Dockerfile `ENV` or `ARG` — visible in image layers and registry
- Secret stored in a ConfigMap — ConfigMaps are not encrypted at rest by default
- Secret mounted as env var exposed via `/proc/<pid>/environ` — prefer volume mounts for sensitive values
- No secret rotation path — secret update requires pod restart, but no rollout is triggered
- `kubectl create secret` with plaintext in shell history — use `--from-file` or a secrets manager

**YAML — ConfigMap for non-sensitive configuration:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-server-config
  namespace: production
data:
  LOG_LEVEL: "info"
  CACHE_TTL_SECONDS: "300"
  FEATURE_NEW_CHECKOUT: "false"
```

**YAML — Secret for credentials, injected as volume mount:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-server-db-secret
  namespace: production
type: Opaque
# In practice: create with `kubectl create secret generic` or external-secrets operator
# Never commit plaintext Secret YAML with real values to git
data:
  DATABASE_URL: <base64-encoded-value>
---
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      volumes:
        - name: db-secret-vol
          secret:
            secretName: api-server-db-secret
            defaultMode: 0400   # read-only, owner only
      containers:
        - name: api
          envFrom:
            - configMapRef:
                name: api-server-config
          volumeMounts:
            - name: db-secret-vol
              mountPath: /etc/secrets
              readOnly: true
          # In application code, read from /etc/secrets/DATABASE_URL
          # Volume mounts auto-update when Secret is rotated; env vars do NOT
```

Note: never use `ENV` with secret values in a Dockerfile — secrets must arrive at runtime via volume mounts or a secrets manager. See Fat Images below for a correct multi-stage Dockerfile.

Cross-reference: `security-patterns-code-review` — secret scanning, external-secrets operator integration, and vault agent sidecar patterns.

---

### 7. Container Anti-Patterns

**CrashLoopBackOff**
Container crashes repeatedly; kubelet applies exponential backoff. Common causes: unhandled startup exception, missing env var/secret, liveness probe too aggressive, entrypoint exits with code 0.
```bash
kubectl logs <pod> --previous && kubectl describe pod <pod>
kubectl get events --sort-by=.lastTimestamp
```

**OOMKilled (exit code 137)**
Container exceeded its memory limit; kernel OOM killer terminated it. Root causes:
- `limits.memory` set too low relative to actual peak usage
- Memory leak in application
- In-memory cache unbounded (no eviction policy)

Fix: increase `limits.memory` to p99 peak + 20% buffer; add memory metrics alert at 80% of limit.

**Pending (never scheduled)**
Pod created but no node can accept it. Root causes:
- Requested more CPU/memory than any node has available
- `nodeSelector` or `nodeAffinity` matches no nodes
- PersistentVolumeClaim not bound (StorageClass unavailable or quota exceeded)
- Too many taints without matching tolerations

**Fat Images**
Images with unnecessary layers, build tools, or full OS. Consequences: slow pull times, large attack surface, more CVEs.

Multi-stage build (correct pattern):
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
USER node
ENTRYPOINT ["node", "dist/index.js"]
```

**Root Containers**
Running as UID 0 inside a container escalates privilege if the container runtime is compromised.

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  readOnlyRootFilesystem: true    # prevent writes to container filesystem
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]                  # drop all Linux capabilities
    add: ["NET_BIND_SERVICE"]      # add only what is explicitly needed
```

**Additional Anti-Pattern Summary:**
| Anti-Pattern | Symptom | Fix |
|---|---|---|
| CrashLoopBackOff | Repeated restarts, backoff delay | Check `kubectl logs --previous`, fix startup crash or probe thresholds |
| OOMKilled | Exit code 137 | Raise `limits.memory`, fix memory leak, add eviction policy to caches |
| Pending forever | Pod stays in Pending state | Check node capacity, affinity rules, PVC binding, taints/tolerations |
| Fat image | Slow deploys, many CVEs | Multi-stage builds, distroless/alpine base, `.dockerignore` |
| Root container | Security audit failure | `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, drop capabilities |
| No resource requests | Random scheduling, evictions | Set `requests.cpu` and `requests.memory` based on observed usage |
| Mutable image tag (`latest`) | Non-reproducible deploys | Pin to digest: `image: myapp@sha256:abc123` |
| HostPath volume mounts | Noisy neighbor, data leakage | Use PersistentVolumeClaim; HostPath only for DaemonSets with explicit justification |

Cross-reference: `microservices-resilience-patterns` — bulkhead and timeout patterns complement the container-level anti-patterns described here.

---

## Cross-References

- `cicd-pipeline-patterns` — rolling update strategy, `maxUnavailable`/`maxSurge`, image promotion gates, and deployment verification hooks
- `microservices-resilience-patterns` — circuit breaker, bulkhead, timeout, and retry patterns at the service-mesh or application layer that complement pod-level health probes
- `security-patterns-code-review` — secret scanning, RBAC audit, container image vulnerability scanning, and network policy review checklists
- `observability-patterns` — resource usage dashboards, OOMKill alerts, HPA scaling events, and probe failure alerting that make the patterns above operationally visible
