# Refactoring & Design Pattern Skills for Claude Code

A comprehensive library of **67 skills** for [Claude Code](https://claude.ai/claude-code) covering refactoring, design patterns, code review, software engineering best practices, microservices, distributed systems, DevOps, security, AI/ML integration, and more across **6 programming languages**. Built from [refactoring.guru](https://refactoring.guru/), Gang of Four patterns, OWASP, and industry best practices.

## Skills Library (67 skills, ~25,000+ lines)

### Refactoring Techniques (8 skills)
| Skill | Coverage |
|-------|----------|
| `refactor` | Orchestration skill — full refactoring pipeline from detection through fix |
| `detect-code-smells` | 23 code smells across 5 categories |
| `refactor-composing-methods` | 9 techniques: Extract Method, Inline Method, etc. |
| `refactor-moving-features` | 8 techniques: Move Method, Extract Class, etc. |
| `refactor-organizing-data` | 15 techniques: Encapsulate Field, Replace Type Code, etc. |
| `refactor-simplifying-conditionals` | 8 techniques: Guard Clauses, Polymorphism, etc. |
| `refactor-simplifying-method-calls` | 14 techniques: Rename Method, Parameter Object, etc. |
| `refactor-generalization` | 12 techniques: Pull Up, Push Down, Template Method, etc. |

### Design Patterns (3 skills)
| Skill | Coverage |
|-------|----------|
| `design-patterns-creational-structural` | 12 GoF patterns: Factory, Builder, Adapter, Decorator, etc. |
| `design-patterns-behavioral` | 11 GoF patterns: Strategy, Observer, Command, State, etc. |
| `architectural-patterns` | 10 patterns: MVC, Clean Architecture, Hexagonal, CQRS, etc. |

### Code Review (11 skills)
| Skill | Coverage |
|-------|----------|
| `review-cheat-sheet` | Master reference — 3-phase review with cross-refs to all skills |
| `review-code-quality-process` | 7-dimension structured review framework |
| `review-solid-clean-code` | 5 SOLID principles + DRY, KISS, YAGNI, Law of Demeter |
| `review-api-contract` | REST, GraphQL, OpenAPI contract review with checklists |
| `refactoring-decision-matrix` | Maps 23 smells to fix techniques with risk/difficulty ratings |
| `review-accuracy-calibration` | Confidence scoring, false positive reduction, severity calibration |
| `ai-generated-code-review` | Patterns for reviewing LLM-generated code |
| `review-feedback-quality` | How to write actionable review comments |
| `review-efficiency-patterns` | Risk-based ordering, time-boxing, when to stop |
| `review-automation-patterns` | Static analysis integration, CI gate configuration |
| `cross-language-review-heuristics` | Universal review signals across all languages |

### Language-Specific Review Guides (6 skills)
| Skill | Coverage |
|-------|----------|
| `go-review-patterns` | Goroutine leaks, context propagation, error handling |
| `python-review-patterns` | Mutable defaults, type hints, GIL, Pythonic idioms |
| `typescript-review-patterns` | Type escape hatches, async pitfalls, React hooks |
| `rust-review-patterns` | Ownership/borrowing, unsafe blocks, lifetimes |
| `java-review-patterns` | Null safety, Stream API, concurrency, generics |
| `cpp-review-patterns` | RAII, undefined behavior, templates, move semantics |

### Anti-Patterns & Performance (3 skills)
| Skill | Coverage |
|-------|----------|
| `anti-patterns-catalog` | 14 design anti-patterns: God Object, Spaghetti Code, etc. |
| `performance-anti-patterns` | 12 performance anti-patterns: N+1, Retry Storm, etc. |
| `pattern-detection-walkthroughs` | 4 end-to-end smell→refactoring→pattern walkthroughs |

### Cross-Cutting Concerns (7 skills)
| Skill | Coverage |
|-------|----------|
| `error-handling-patterns` | 10 patterns across TypeScript, Go, Rust, Python, Java |
| `concurrency-patterns` | 10 patterns: Race Conditions, Deadlocks, Actor Model, etc. |
| `security-patterns-code-review` | 14 OWASP-aligned security review areas |
| `testing-patterns` | Test doubles, 9 test smells, AAA/FIRST, TDD anti-patterns |
| `observability-patterns` | Logging, Tracing, Metrics, Health Checks, Alerting |
| `database-review-patterns` | 12 database review areas: N+1, migrations, indexes, etc. |
| `dependency-injection-module-patterns` | 8 DI patterns, Composition Root, module organization |

### Language & Type Skills (3 skills)
| Skill | Coverage |
|-------|----------|
| `language-specific-idioms` | Idioms for TypeScript, Python, Java, Go, Rust, C++ |
| `type-system-patterns` | 10 type patterns: Branded Types, Phantom Types, etc. |
| `refactor-functional-patterns` | 8 FP patterns: Pure Functions, Composition, Monads, etc. |

### Domain & Architecture (3 skills)
| Skill | Coverage |
|-------|----------|
| `domain-driven-design-patterns` | Bounded Contexts, Aggregates, Value Objects, Domain Events, Context Mapping |
| `event-sourcing-cqrs-patterns` | Event Sourcing, CQRS, projections, snapshots, event schema evolution |
| `migration-patterns` | Strangler Fig, Anti-Corruption Layer, Branch by Abstraction, Expand-Contract, CDC |

### Microservices & Distributed Systems (3 skills)
| Skill | Coverage |
|-------|----------|
| `microservices-resilience-patterns` | Saga, Bulkhead, Circuit Breaker, Retry, API Gateway, Service Mesh |
| `message-queue-patterns` | Pub/Sub, Competing Consumers, Outbox, DLQ, Kafka partitions, exactly-once |
| `real-time-communication-patterns` | WebSocket, SSE, long polling, Redis Pub/Sub scaling, auth at upgrade |

### DevOps & Infrastructure (3 skills)
| Skill | Coverage |
|-------|----------|
| `cicd-pipeline-patterns` | Pipeline stages, GitOps, deployment strategies, SLSA, shift-left testing |
| `container-kubernetes-patterns` | Health probes, HPA/KEDA, PDB, RBAC, graceful shutdown, anti-patterns |
| `feature-flags-progressive-delivery` | Feature toggles, canary/blue-green/ring deployments, A/B testing, kill switches |

### Data & Search (4 skills)
| Skill | Coverage |
|-------|----------|
| `data-pipeline-patterns` | ETL/ELT, batch vs streaming, idempotency, watermarking, schema evolution, DAG design |
| `search-indexing-patterns` | Elasticsearch/OpenSearch mapping, ILM, query/aggregation patterns, PostgreSQL FTS |
| `caching-strategies` | Cache-aside/read-through/write-through, stampede prevention, CDN, eviction policies |
| `data-validation-schema-patterns` | Zod, Pydantic v2, Bean Validation, schema evolution, coercion vs strict parsing |

### API & Communication (2 skills)
| Skill | Coverage |
|-------|----------|
| `graphql-grpc-api-patterns` | Schema design, N+1/DataLoader, Protobuf field numbering, gRPC streaming, breaking changes |
| `api-rate-limiting-throttling` | Token Bucket, Leaky Bucket, Sliding Window, Redis Lua scripts, client-side backoff |

### Security & Auth (2 skills)
| Skill | Coverage |
|-------|----------|
| `auth-authz-patterns` | OAuth2, OIDC, JWT, RBAC/ABAC, mTLS, service-to-service auth, session security |
| `multi-tenancy-patterns` | RLS, schema-per-tenant, DB-per-tenant, tenant context propagation, tenant-aware caching |

### Frontend & Client (3 skills)
| Skill | Coverage |
|-------|----------|
| `state-management-patterns` | Flux/Redux, React Query/SWR, optimistic updates, XState FSM, session management |
| `i18n-l10n-patterns` | ICU MessageFormat, CLDR plurals, Intl API, RTL layout, pseudo-localization testing |
| `file-upload-media-patterns` | Multipart uploads, chunked transfer, presigned URLs, media processing pipelines, storage strategies |

### Documentation & Observability (2 skills)
| Skill | Coverage |
|-------|----------|
| `code-documentation-patterns` | ADRs, OpenAPI/AsyncAPI, README standards, runbooks, technical debt registers |
| `distributed-tracing-patterns` | OpenTelemetry, span design, context propagation, sampling strategies, trace-based testing |

### AI & ML (1 skill)
| Skill | Coverage |
|-------|----------|
| `ai-ml-integration-patterns` | LLM integration, prompt engineering, RAG pipelines, model versioning, evaluation frameworks, cost optimization |

### Developer Experience (1 skill)
| Skill | Coverage |
|-------|----------|
| `developer-experience-patterns` | DX metrics, onboarding flows, CLI ergonomics, toolchain design, feedback loops, documentation-as-code |

### Skill Catalog (1 skill)
| Skill | Coverage |
|-------|----------|
| `skill-catalog` | Master index of all skills with usage guidance and cross-references |

## Installation

```bash
git clone https://github.com/mickeyyaya/refactoring-skills-claude-code.git
cd refactoring-skills-claude-code
./install.sh            # Claude Code (default)
```

### Multi-Platform Support

Works with **any LLM CLI tool**. The installer adapts skills to each platform's native format:

```bash
./install.sh --claude        # ~/.claude/skills/ (default)
./install.sh --cursor        # .cursorrules + .cursor/rules/
./install.sh --copilot       # .github/copilot-instructions.md
./install.sh --aider         # .aider-rules.md + .aider.conf.yml
./install.sh --windsurf      # .windsurfrules
./install.sh --codex         # AGENTS.md (OpenAI Codex CLI)
./install.sh --gemini        # GEMINI.md (Google Gemini CLI)
./install.sh --continue      # .continue/rules/
./install.sh --export        # Print to stdout (pipe to any file)
./install.sh --all           # Install to all detected platforms
```

Target a specific project directory:

```bash
./install.sh --copilot --project-dir ~/my-project
./install.sh --all --project-dir ~/my-project
```

| Platform | Target File(s) | Format |
|----------|----------------|--------|
| Claude Code | `~/.claude/skills/{name}/SKILL.md` | Individual Markdown files |
| Cursor | `.cursorrules` + `.cursor/rules/*.md` | Concatenated + individual |
| GitHub Copilot | `.github/copilot-instructions.md` | Single concatenated file |
| Aider | `.aider-rules.md` | Single concatenated file |
| Windsurf | `.windsurfrules` | Single concatenated file |
| OpenAI Codex | `AGENTS.md` | Single concatenated file |
| Gemini CLI | `GEMINI.md` | Single concatenated file |
| Continue.dev | `.continue/rules/*.md` | Individual Markdown files |

See [`adapters/FORMATS.md`](adapters/FORMATS.md) for details on each platform's format.

## How It Works

Skills activate automatically based on context. Start any code review with `/review-cheat-sheet` for the master reference, or let Claude Code match the right skill to your task:

- **Code review** → `review-cheat-sheet` (master), `review-code-quality-process` (detailed)
- **Code smells** → `detect-code-smells` → `refactoring-decision-matrix` → specific refactoring skill
- **Design decisions** → `design-patterns-*`, `architectural-patterns`
- **Security review** → `security-patterns-code-review`, `auth-authz-patterns`
- **Performance issues** → `performance-anti-patterns`, `database-review-patterns`, `caching-strategies`
- **Language-specific** → `language-specific-idioms`, `type-system-patterns`
- **Distributed systems** → `microservices-resilience-patterns`, `message-queue-patterns`, `event-sourcing-cqrs-patterns`
- **Infrastructure** → `cicd-pipeline-patterns`, `container-kubernetes-patterns`, `feature-flags-progressive-delivery`
- **Data & search** → `data-pipeline-patterns`, `search-indexing-patterns`, `caching-strategies`
- **APIs** → `graphql-grpc-api-patterns`, `api-rate-limiting-throttling`, `review-api-contract`
- **Domain modeling** → `domain-driven-design-patterns`, `migration-patterns`
- **Frontend** → `state-management-patterns`, `i18n-l10n-patterns`, `file-upload-media-patterns`
- **Observability** → `observability-patterns`, `distributed-tracing-patterns`
- **Documentation** → `code-documentation-patterns`
- **Multi-tenant systems** → `multi-tenancy-patterns`
- **AI/ML integration** → `ai-ml-integration-patterns`
- **Developer experience** → `developer-experience-patterns`
- **Skill discovery** → `skill-catalog`

## Coverage Summary

| Category | Count |
|----------|-------|
| Code Smells | 23 |
| Refactoring Techniques | 66 |
| GoF Design Patterns | 23 |
| Architectural Patterns | 10 |
| Anti-Patterns | 26 (14 design + 12 performance) |
| Security Review Areas | 14 (OWASP-aligned) |
| Error Handling Patterns | 10 |
| Concurrency Patterns | 10 |
| Testing Patterns | 9 test smells + 5 test doubles |
| Database Review Areas | 12 |
| Observability Patterns | 8 |
| DI/Module Patterns | 8 |
| Type System Patterns | 10 |
| FP Patterns | 8 |
| DDD Patterns | Bounded Contexts, Aggregates, Value Objects, Domain Events |
| Microservices Patterns | Saga, Circuit Breaker, Bulkhead, API Gateway, Service Mesh |
| Messaging Patterns | Pub/Sub, Outbox, DLQ, Kafka, exactly-once delivery |
| CI/CD Patterns | Pipeline stages, GitOps, blue-green, canary, SLSA |
| Caching Patterns | Cache-aside, read/write-through, stampede prevention, CDN |
| Auth/Authz Patterns | OAuth2, OIDC, JWT, RBAC, ABAC, mTLS |
| AI/ML Patterns | LLM integration, RAG, prompt engineering, model versioning |
| Languages Covered | 6 (TypeScript, Python, Java, Go, Rust, C++) |

## License

MIT
