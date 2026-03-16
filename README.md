# Refactoring Skills for Claude Code

A comprehensive set of 7 refactoring skills for [Claude Code](https://claude.ai/claude-code) based on the techniques from [refactoring.guru](https://refactoring.guru/). Covers all **66 refactoring techniques** and **23 code smells** organized into actionable, workflow-oriented skills.

## Skills

| Skill | Techniques | Purpose |
|-------|-----------|---------|
| `detect-code-smells` | 23 smells, 5 categories | Identify code quality issues and find the right fix |
| `refactor-composing-methods` | 9 techniques | Break down long methods and simplify expressions |
| `refactor-moving-features` | 8 techniques | Redistribute responsibilities between classes |
| `refactor-organizing-data` | 15 techniques | Encapsulation, type codes, and data handling |
| `refactor-simplifying-conditionals` | 8 techniques | Flatten and clarify conditional logic |
| `refactor-simplifying-method-calls` | 14 techniques | Clean method interfaces and signatures |
| `refactor-generalization` | 12 techniques | Manage inheritance hierarchies and delegation |

## Installation

### Quick Install (recommended)

```bash
./install.sh
```

This copies all skills into `~/.claude/skills/` where Claude Code automatically discovers them.

### Manual Install

Copy the skill directories into your Claude Code skills directory:

```bash
cp -r skills/* ~/.claude/skills/
```

### Per-Project Install

To install skills for a specific project only:

```bash
cp -r skills/* /path/to/your/project/.claude/skills/
```

## Usage

Once installed, Claude Code automatically activates the relevant skill when you:

- Ask to **review code** for quality issues → `detect-code-smells`
- Work with **long methods** or duplicate code → `refactor-composing-methods`
- Need to **move responsibilities** between classes → `refactor-moving-features`
- Deal with **primitives, type codes, or data classes** → `refactor-organizing-data`
- Encounter **complex conditionals** → `refactor-simplifying-conditionals`
- See **confusing method interfaces** → `refactor-simplifying-method-calls`
- Manage **inheritance hierarchies** → `refactor-generalization`

You can also invoke skills directly:

```
/detect-code-smells
/refactor-composing-methods
/refactor-simplifying-conditionals
```

## Skill Design

Each skill follows a consistent structure:

1. **Quick Reference Table** — scannable overview of all techniques
2. **Detailed Techniques** — problem/solution with before/after TypeScript examples
3. **Decision Flowchart** — guides you to the right technique
4. **Common Mistakes** — what goes wrong and how to avoid it
5. **Cross-references** — links to related skills for connected smells

### Cross-Referencing

The `detect-code-smells` skill serves as the entry point. Each smell points to the specific technique skill that fixes it, so you can start by identifying the problem and follow the trail to the solution.

## Coverage

### Code Smells (23 total)

**Bloaters:** Long Method, Large Class, Primitive Obsession, Long Parameter List, Data Clumps

**OO Abusers:** Switch Statements, Temporary Field, Refused Bequest, Alternative Classes with Different Interfaces

**Change Preventers:** Divergent Change, Shotgun Surgery, Parallel Inheritance Hierarchies

**Dispensables:** Comments (excessive), Duplicate Code, Lazy Class, Data Class, Dead Code, Speculative Generality

**Couplers:** Feature Envy, Inappropriate Intimacy, Message Chains, Middle Man, Incomplete Library Class

### Refactoring Techniques (66 total)

All techniques from the six categories defined at refactoring.guru are covered:

- Composing Methods (9)
- Moving Features Between Objects (8)
- Organizing Data (15)
- Simplifying Conditional Expressions (8)
- Simplifying Method Calls (14)
- Dealing with Generalization (12)

## License

MIT
