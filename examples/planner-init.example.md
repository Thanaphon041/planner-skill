# SKILL: Planner Init — Load Project Context

**Purpose:** Generic project-context loader. Auto-invoked by `/planner run` (E0.5) before phase execution to give Sonnet a foundation in the project's architecture and conventions.

This is a **fallback init skill** auto-installed by `/planner setup` if the project doesn't already have a richer init (e.g. one that loads OpenAPI specs, design tokens, etc.). If your team builds a better one, replace this file or change the `Skill(skill=...)` reference in `planner.md` E0.5.

---

## Steps

### 1. Confirm project root

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
echo "Project root: $PROJECT_ROOT"
```

### 2. Read top-level architecture docs (if present)

Read these files if they exist (each is optional — skip silently if missing):

- `$PROJECT_ROOT/CLAUDE.md` — auto-injected by Claude Code, but explicit re-read is fine
- `$PROJECT_ROOT/AGENTS.md` — top-level agent guide
- `$PROJECT_ROOT/README.md` — only first 100 lines (overview)
- `$PROJECT_ROOT/ARCHITECTURE.md` — if exists
- `$PROJECT_ROOT/docs/architecture.md` — alternate path
- `$PROJECT_ROOT/.claude/AGENTS.md` — claude-specific guide

### 3. Discover module-level AGENTS.md files

```bash
find "$PROJECT_ROOT" -maxdepth 3 -name "AGENTS.md" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -20
```

If the upcoming phase touches specific modules (check `Files to modify` in the phase file), prefer reading their `AGENTS.md` over the top-level one.

### 4. Read package metadata (pick whichever exists)

- `package.json` — Node/JS projects
- `Cargo.toml` — Rust
- `pyproject.toml` / `setup.py` — Python
- `go.mod` — Go
- `build.gradle.kts` / `build.gradle` — JVM/Android
- `Package.swift` — Swift
- `pom.xml` — Maven/Java

Just enough to know: package name, main dependencies, build tool.

### 5. Quick git status

```bash
git -C "$PROJECT_ROOT" status --short
git -C "$PROJECT_ROOT" branch --show-current
```

### 6. Acknowledge

Echo a one-line confirmation:

```
✅ Project context loaded: <package-name> · branch=<current> · <N> modules detected
```

---

## What this skill does NOT do

- Run tests / builds (that's the phase's job, not init)
- Read every source file (only architecture-level docs)
- Parse OpenAPI / GraphQL schemas (if your project needs that, write a richer init skill)
- Load design tokens / theme files (same — extend if needed)

Keep init lightweight (≤ 5k tokens of reads). Heavy context belongs in the phase's `Files to read` list.

---

## When to replace this skill

This generic init is a starting point. Replace it with a project-specific one when:

- You have a custom architecture (microservices, monorepo with workspaces)
- There's domain knowledge that every session needs (e.g. business glossary)
- Tests follow a specific pattern that needs explanation
- You have a code style guide that's not in CLAUDE.md

Just save your replacement at `.claude/commands/planner-init.md` (same filename) and `/planner run` will keep using it.
