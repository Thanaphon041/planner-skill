# Changelog

All notable changes to the Claude Planner Skill.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · semver-ish (we don't release tags yet, just date-stamped milestones).

---

## 0.4.0 — Claude Code plugin packaging + setup config + force-push

### Added
- **Packaged as a Claude Code plugin** — installable via `claude plugin marketplace add` + `claude plugin install` (no more manual `install.sh` + hook wiring). See README "Install" section.
- `/planner help` mode — print mode reference + key paths + typical flow
- `CHANGELOG.md` (this file) for tracking changes across upgrades
- `install.sh` backs up existing `planner.md` before overwriting on re-run (kept for non-plugin / legacy installs)
- **`/planner setup` now asks for base branch** (interactive prompt) — which branch new plans should fork from (e.g. `develop`, `main`). Validated against `origin/`.
- Runtime config file `.claude/worktrees/_plans/.planner-config.sh` written by setup; sourced by every mode in Path resolution. Travels with the plans branch so teammates inherit the same config.

### Changed
- `install.sh` no longer asks for base branch (moved to `/planner setup`); no longer substitutes `<base-branch>` placeholder. Bash code uses `$PLANNER_BASE_BRANCH` from runtime config; the placeholder remains in prose for documentation.
- Setup mode reorganized from 7 to 8 steps (SU0..SU8): SU0 collects user answer, SU6 writes config, SU7 self-heals init skill (was SU6), SU8 echoes summary.
- **E10 now pushes the feature branch at every phase end** (was: commit only, push deferred to FEATURE COMPLETE). Each phase is a checkpoint — pushing means work survives a lost laptop, teammates see progress, CI runs per phase. Stop hook enforces it: blocks if the phase's code commit isn't pushed (checks `@{u}..HEAD` — no upstream or unpushed commits → block).

### Not added (considered but rejected)
- UI language config — Claude already mirrors user's prompt language; adding a config knob is over-engineering. Artifacts stay English by rule.

### Translated
- 152 lines of Thai prose in `planner.md` → English (rationale comments, table cells, bash echo strings, instructional phrases). Behavior unchanged.

---

## 2026-05-07 — list/cleanup/abort + cleanup prompt + init fallback

### Added
- **`/planner list`** mode — show all plans (active + complete + archived) with cost summaries
- **`/planner cleanup <slug>`** mode — archive a completed plan (validates completeness)
- **`/planner abort <slug> [<reason>]`** mode — mark plan ❌ abandoned without deleting files
- **Auto-installed fallback init skill** (`planner-init.md`) when project doesn't specify `PLANNER_INIT_SKILL`
- **Self-heal in `/planner setup`** — re-installs the fallback init skill if missing
- README: full **Example Output** section with concrete sample for every mode

### Changed
- **Auto-cleanup → cleanup prompt** on FEATURE COMPLETE: user picks `[k]eep` (default) or `[d]elete`. Token + USD totals shown before the prompt.
- **Cost estimate formula recalibrated** (P4.5) — old constants underestimated by ~5×. New formula models cache growth, per-task turn scaling, output multiplier. Within ±30% of measured actuals (was -82% off).
- **Cost estimate range hint** ±50% → ±30% (calibrated)
- Phase template per-phase examples: `$0.55-0.74` → `$2.00-3.30` (calibrated baseline)
- Token display ≥1M shows as `X.XM` (was `~X,XXXk`)
- Status mode COSTS block split into "Done so far" (actual) + "Remaining" (est) + projected total
- Phase-end summary shows cumulative cost alongside per-phase

### Fixed
- **JSONL dedupe by `(message_id, usage signature)`** — was double-counting because each turn has 2-3 records (response + result snapshots). Costs were ~1.5-2× over actual.
- **Marker detection bugs** in P8.0 (planning) and E10 (per-phase):
  - Skill body self-match: regex `<command-name>/?planner</command-name>` matched the skill's own documentation when injected as conversation content
  - Silent fallback to whole-file sum when marker not found (race) → now emits `?` instead
- `install.sh` interactive detection: `exec </dev/tty` no longer aborts in CI / closed-stdin environments

---

## 2026-05-06 — initial portable extraction

### Added
- Extracted from GruChat project as portable skill
- 4 modes: `setup`, `<feature>` (planning), `run`, `status`
- Dedicated orphan `plans` branch architecture
- Two-commit workflow (code → feature branch, status → plans branch)
- Token + USD cost tracking via JSONL session logs (Opus / Sonnet / Haiku 4.x pricing)
- Auto-fix branch resolution (E3): stash, checkout, pivot, takeover, create
- PreToolUse hook (phase reminder) + Stop hook (2-commit enforcement)
- `install.sh` with interactive prompts + env-var override + `gh` CLI fallback for private repos
- Examples folder: `CLAUDE.example.md`, `settings.example.json`, `planner-init.example.md`

[0.4.0]: https://github.com/Thanaphon041/planner-skill
