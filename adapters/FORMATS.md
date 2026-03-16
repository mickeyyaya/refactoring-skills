# LLM CLI Adapter Formats

This document describes how each LLM CLI tool discovers custom instructions, and how the universal `rules/` format maps to each.

## Universal Format (`rules/`)

Skills are stored as plain Markdown files in `rules/`. Each file is self-contained with a YAML frontmatter header:

```yaml
---
name: skill-name
description: One-line trigger description
category: refactoring | design-patterns | review | anti-patterns | cross-cutting | language
---

# Skill Title

Content...
```

This format is readable by any LLM — it's just Markdown. The adapters below convert it into the native format each tool expects.

## Supported Platforms

| Platform | Config Location | Format | Adapter |
|----------|----------------|--------|---------|
| Claude Code | `~/.claude/skills/{name}/SKILL.md` | Markdown with frontmatter | `install.sh --claude` |
| Cursor | `.cursorrules` or `.cursor/rules/` | Plain Markdown (concatenated) | `install.sh --cursor` |
| GitHub Copilot | `.github/copilot-instructions.md` | Single Markdown file | `install.sh --copilot` |
| Aider | `.aider.conf.yml` + convention files | YAML config + Markdown | `install.sh --aider` |
| Windsurf (Codeium) | `.windsurfrules` | Plain Markdown | `install.sh --windsurf` |
| Codex (OpenAI) | `AGENTS.md` or `codex.md` | Markdown | `install.sh --codex` |
| Gemini CLI | `GEMINI.md` | Markdown | `install.sh --gemini` |
| Continue.dev | `.continue/config.json` + rules/ | JSON config + Markdown | `install.sh --continue` |
| Any LLM | stdout | Concatenated Markdown | `install.sh --export` |

## How Each Adapter Works

### Claude Code (`--claude`)
Copies each `rules/{name}.md` → `~/.claude/skills/{name}/SKILL.md` preserving frontmatter.

### Cursor (`--cursor`)
Generates `.cursorrules` by concatenating selected rules with section headers. Also supports `.cursor/rules/{name}.md` for newer Cursor versions.

### GitHub Copilot (`--copilot`)
Generates `.github/copilot-instructions.md` — a single file with all rules concatenated under category headers.

### Aider (`--aider`)
Generates `.aider.conf.yml` with a `read` directive pointing to a generated `.aider-rules.md` file containing concatenated rules.

### Windsurf (`--windsurf`)
Generates `.windsurfrules` — same format as Cursor, single concatenated file.

### Codex / OpenAI CLI (`--codex`)
Generates `AGENTS.md` at project root with all rules.

### Gemini CLI (`--gemini`)
Generates `GEMINI.md` at project root with all rules.

### Continue.dev (`--continue`)
Copies rules as `.continue/rules/{name}.md` and updates `.continue/config.json`.

### Export (`--export`)
Prints all rules to stdout as a single concatenated document. Pipe to any file for any tool.
