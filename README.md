# Refactoring & Design Pattern Skills for Claude Code

A comprehensive library of **28 skills** for [Claude Code](https://claude.ai/claude-code) covering refactoring, design patterns, code review, and software engineering best practices across **6 programming languages**. Built from [refactoring.guru](https://refactoring.guru/), Gang of Four patterns, OWASP, and industry best practices.

## Skills Library (28 skills, ~9,700 lines)

### Refactoring Techniques (7 skills)
| Skill | Coverage |
|-------|----------|
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

### Code Review (5 skills)
| Skill | Coverage |
|-------|----------|
| `review-cheat-sheet` | Master reference — 3-phase review with cross-refs to all skills |
| `review-code-quality-process` | 7-dimension structured review framework |
| `review-solid-clean-code` | 5 SOLID principles + DRY, KISS, YAGNI, Law of Demeter |
| `review-api-contract` | REST, GraphQL, OpenAPI contract review with checklists |
| `refactoring-decision-matrix` | Maps 23 smells to fix techniques with risk/difficulty ratings |

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
- **Security review** → `security-patterns-code-review`
- **Performance issues** → `performance-anti-patterns`, `database-review-patterns`
- **Language-specific** → `language-specific-idioms`, `type-system-patterns`

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
| Languages Covered | 6 (TypeScript, Python, Java, Go, Rust, C++) |

## License

MIT
