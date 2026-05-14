# Planner — Claude Code Plugin

Phase-based planning workflow for [Claude Code](https://claude.com/claude-code) — designed for features that don't fit in one context window.

**Core idea:** A high-context model (Opus) plans the work into self-contained phases stored in a dedicated git branch; a fresh-context model (Sonnet) executes one phase per session. Project context, tokens, and dollar costs tracked across the whole feature lifecycle.

---

## Install

### Recommended — Claude Code plugin

```bash
claude plugin marketplace add Thanaphon041/planner-skill
claude plugin install planner@planner-skill
```

That's it — the slash command and both hooks (phase reminder + 2-commit-push enforcement) are wired automatically. No `install.sh`, no manual `settings.json` editing.

Update later with `/plugin marketplace update` then `/plugin update planner@planner-skill`.

The command is `/planner:planner` (plugin `planner`, command `planner`); the mode is passed as an argument — `/planner:planner run`, `/planner:planner status`, etc.

### Alternative — `install.sh` (non-plugin)

For projects that can't use plugins, or to vendor the skill directly into `.claude/`:

```bash
gh api /repos/Thanaphon041/planner-skill/contents/install.sh --jq .content \
  | base64 -d | bash -s -- ~/projects/my-app
```

The installer asks 2 questions (init skill name, test command), copies `commands/planner.md` → `.claude/commands/`, copies hooks, and prints the manual steps to wire hooks in `settings.json`. See [FAQ](#faq) for local-clone / public-fork variants.

### After install — one-time per machine

```
/planner setup
```

Bootstraps the orphan `plans` branch + `_plans` worktree, and **asks 1 question:**
- **Base branch** (e.g. `develop`, `main`) — which branch new feature plans should fork from

It persists in `.claude/worktrees/_plans/.planner-config.sh` on the plans branch, so teammates inherit the same config when they run setup.

> **Note on language:** Claude already mirrors your prompt language naturally — type in Thai, get Thai responses; type in English, get English. No config needed. Artifacts (commit messages, code, plan files, branch names) always stay in English so git history works for international teams.

### Use it

```
/planner <feature description>     ← Opus plans
/planner run                       ← Sonnet executes one phase
/planner status [<slug>]           ← read-only progress for one plan
/planner list                      ← all plans (active + archived)
/planner cleanup <slug>            ← archive completed plan
/planner abort <slug> [<reason>]   ← mark plan abandoned
/planner help                      ← mode reference + paths
```

---

## Why?

Real-world features often exceed Claude's 200k context window when you try to plan **and** implement in one session:

```
One session, no planner:
  Read 50 files for context  →  150k tokens
  Design + implement         →  250k tokens
  → context overflow / quality rot before phase 2
```

The planner splits the work across sessions:

```
/planner <feature>   →  Opus plans the whole feature   (~$10-30, one time)
/planner run         →  Sonnet implements phase 01     (~$2-4, fresh context)
/planner run         →  Sonnet implements phase 02     (~$2-4, fresh context)
...                  →  each phase = a clean 200k window
/planner status      →  read-only progress check
```

Costs scale with feature size — small features (2-3 phases) ~$15, large features (5-7 phases) ~$40-60. When all phases are done → cleanup prompt (keep or archive) + total cost report.

> **Note on command syntax:** installed as a plugin, the command is namespaced — you actually type `/planner:planner <args>`. This README writes `/planner <args>` everywhere for readability.

---

## What does this prevent?

The planner's main value isn't token savings — it's **preventing context rot** and the mistakes that come with it. Claude's 200k context window degrades in quality well before the hard limit; long sessions (80+ turns) on a single feature reliably produce subtle errors.

### 🐛 Failure modes — frequency comparison

| Failure mode | Without planner | With planner | What prevents it |
|---|---|---|---|
| Architecture rule violated (e.g. layering break) | ~30% phases | ~5% | Init skill reloads project rules each phase |
| Claims "tests pass" without actually running | ~40% phases | ~10% | Acceptance criteria explicit in phase file |
| Edits files outside phase scope (scope creep) | ~50% turns | ~10% | PreToolUse hook re-injects scope before edits |
| Forgets earlier decisions, re-asks architecture | ~60% sessions | ~5% | Decisions Log in `_overview.md` |
| Uses stale API after a refactor | ~30% turns | ~10% | Fresh `/clear` per phase + re-load context |
| Hallucinates non-existent file paths | ~20% | ~5% | Phase file lists real paths (verified at plan time) |
| Forgets to commit / push | ~35% phases | ~5% | 2-commit-push workflow, enforced by Stop hook |
| Commits to wrong branch | ~25% | ~0% | Branch resolution (E3) auto-fixes |
| Leaves TODO / placeholder in code | ~30% phases | ~10% | Acceptance criteria checkboxes |
| Skips the build/test check | ~50% phases | ~15% | Acceptance criteria + Stop hook |
| Status update doesn't match actual work done | N/A | ~5% | Stop hook blocks if tasks not ticked |

> Numbers are estimates from observed patterns, not benchmarked. Real rates depend heavily on feature complexity and codebase size.

### 📊 Net impact

| Metric | Without | With | Δ |
|---|---|---|---|
| Avg context per turn | 110-180k | 50-100k | **-45%** |
| Quality consistency on long tasks | 50-60% | 90-95% | **+50%** |
| Repeat-work rate (rework after a mistake) | 30-40% of turns | 5-10% | **-75%** |
| Token cost vs disciplined manual workflow | baseline | -10-15% | small saving |
| Token cost vs naive Opus 1-session | baseline | -70% | large saving |
| Total time on large features | baseline | -20-30% | faster |
| Total time on small features (1-2 phases) | baseline | +15% | slower (overhead) |
| Resumability across sessions/days | ~30% success | ~95% | **+200%** |
| Cost traceability per feature | 0% | 100% | per-phase tracked |

### 🎯 When to use vs not

| Scenario | Verdict |
|---|---|
| Feature spanning 4+ phases / multiple modules | 🟢 **Use it** — net +30-50% productivity, lower mistake rate |
| Feature 2-3 phases | 🟡 Use if you value structure — net 0 to +15% |
| Small fix / single-file change | 🔴 **Don't use** — planning overhead isn't worth it |

### 🧠 Why it helps

Three mechanisms acting independently:

1. **Context refresh between phases** — `/clear` resets the baseline to ~50k. Phase 5 runs as fresh as phase 1, instead of dragging accumulated context.
2. **Hooks act as bouncers** — the PreToolUse hook re-injects the current phase's scope before every edit (combats "lost in the middle"); the Stop hook blocks if the 2-commit-push workflow is incomplete.
3. **Phase file is the single source of truth** — `Files to read`, `Files to modify`, `Tasks`, `Acceptance criteria` are explicit. No exploration, no guessing, no re-asking.

### ⚠️ What it does NOT prevent

- Logic bugs in code
- Edge cases your tests don't cover
- Performance issues / race conditions
- Stale test fixtures
- Bad architecture decisions made during planning

These still require code review.

---

## Features

- **8 modes** routed by first arg: `setup`, `<feature>` (planning), `run`, `status`, `list`, `cleanup`, `abort`, `help`
- **Dedicated `plans` branch** — orphan branch holding only `docs/plans/<slug>/` files. Feature branches stay 100% code.
- **Auto-fix everything** — wrong branch? Stash + checkout. Plan branch on another worktree? Pivot it. Plan branch missing? Auto-create from base.
- **Two-commit workflow** — code → feature branch, status → plans branch. Stop hook enforces.
- **Token + USD cost tracking** — read from Claude Code's JSONL session logs, marker-based per-phase attribution with dedupe.
- **Cost estimation** — formula calibrated against actuals (within ±30%); estimates fixed at plan time.
- **Cleanup prompt on completion** — when all phases ✅, asks user to keep or archive plan files.
- **Self-healing init skill** — auto-installs fallback project-context loader if missing.
- **Hooks** — phase reminder injected before code edits, stop hook blocks if 2-commit workflow incomplete.

---

## Example Output

### `/planner setup` — bootstrap (one-time per machine)

```
✅ Planner setup complete
   Plans worktree: /Users/you/projects/my-app/.claude/worktrees/_plans
   Branch:         plans (orphan)
   Remote:         origin/plans (synced)
   Base branch:    develop
   Init skill:     planner-init

Next: use /planner <feature> to create your first plan
```

If your project has no init skill, the fallback `planner-init` is auto-installed at `.claude/commands/planner-init.md`.

---

### `/planner <feature>` — Opus plans (one-time per feature)

**Input:** `/planner add @mention support to group chat rooms`

**Output (after Opus explores codebase + writes plan files):**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  PLAN SAVED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Slug          mention-in-group
  Code branch   feature/mention-in-group
  Plans branch  plans @ d6f16913

──────────────────────────────────────────────
📋  PHASES (5)
──────────────────────────────────────────────

  01  SDK + UseCase plumbing
      read ~25k  · output ~250 lines  · est ~$2.00
  02  Composer mention detection + state
      read ~30k  · output ~400 lines  · est ~$3.30
  03  ViewModel ↔ Composer wiring
      read ~25k  · output ~250 lines  · est ~$2.00
  04  TextBubble mention rendering
      read ~20k  · output ~300 lines  · est ~$2.50
  05  Localization + permission gate
      read ~15k  · output ~150 lines  · est ~$1.20

──────────────────────────────────────────────
💸  PLANNING COST (this Opus session)
──────────────────────────────────────────────

  Tokens   ~9.2M
  USD      $24.63  (Opus model)

  Planning is one-time per feature.
  Phase execution will use Sonnet (cheaper).

──────────────────────────────────────────────
💰  ESTIMATED PHASE TOTAL (forward)
──────────────────────────────────────────────

  ~24M tokens  ·  ~$11.00
  (Sonnet 4.6 assumed, ±30% range)

──────────────────────────────────────────────
🧮  EXPECTED FEATURE COST
──────────────────────────────────────────────

  Plan + 5 phases  ≈  $24.63 + $11.00  =  ~$36

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
👉  START PHASE 01 — Pick one:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Option A — Same session (faster ~30s)
      /clear
      → switch model to Sonnet 4.6 (UI)
      /planner run

  Option B — New session (clean slate)
      1. Close Claude Code
      2. Open at any feature worktree, pick Sonnet 4.6
      3. /planner run
```

After this output, Opus **HARD STOPs** to prevent accidentally implementing phase 01 on Opus (~5× cost vs Sonnet).

---

### `/planner run` — Sonnet executes one phase

Sonnet reads the phase file, implements the tasks, runs the acceptance checks, commits + pushes both branches, then hands off:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  PHASE 02 DONE — Composer mention detection + state
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Tasks      6/6 ✅      Acceptance  3/3 ✅
  Code       a1b2c3d  pushed → feature/mention-in-group
  Status     e4f5g6h  pushed → plans

  This phase   ~7.2M  · $3.61   (est was $3.30)
  Cumulative   ~16.4M · $31.67  (Plan + phase 01-02)
  Remaining    3 phases · est ~$5.70

  Next: /clear → /planner run   (phase 03 — ViewModel ↔ Composer wiring)
```

---

### `/planner status` — read-only progress check

Progress dashboard with phase checklist + cost breakdown (actual ✅ rows + ⬜ remaining estimates):

```
📋  PLAN: Group Chat Mention Support     2/5 done   ▓▓▓▓░░░░░░  40%

  ✅  01  SDK + UseCase plumbing             9de6ef20
  ✅  02  Composer mention detection + state c4e92f01
  ⬜  03  ViewModel ↔ Composer wiring         pending
  ⬜  04  TextBubble mention rendering        pending
  ⬜  05  Localization + permission gate      pending

💰  Spent: ~23.2M · $31.67   Est remaining: ~14.2M · ~$5.70
```

Full output also includes goal of current phase, top decisions, recent commits.

---

### Last phase complete — cleanup prompt

When all phases ✅, the planner shows the full cost breakdown and asks before deleting plan files:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎉  FEATURE COMPLETE — mention-in-group
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  All phases  ✅  5/5
  Last code commit    f8d2e91a  (feature/mention-in-group)

──────────────────────────────────────────────
💰  COST BREAKDOWN
──────────────────────────────────────────────

  Plan        ~9.2M    ·  $24.63   (opus)
  Phase 01    ~6.8M    ·  $3.43    (sonnet)
  Phase 02    ~7.2M    ·  $3.61    (sonnet)
  Phase 03    ~5.1M    ·  $2.55    (sonnet)
  Phase 04    ~6.4M    ·  $3.20    (sonnet)
  Phase 05    ~3.8M    ·  $1.90    (sonnet)
                ───────    ─────
  Total       ~38.5M    ·  $39.32

  Estimate was $35.63 → actual $39.32  (+10%)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀  NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1.  Push feature branch:
      git push -u origin feature/mention-in-group

  2.  Create PR:
      gh pr create --base main \
        --title "feat: group chat @mention support"

──────────────────────────────────────────────
🗑️   CLEANUP PROMPT
──────────────────────────────────────────────

  Plan files at: docs/plans/mention-in-group/  (overview + 5 phase files)
  Total used:    ~38.5M  ·  $39.32

  Delete plan folder from plans branch tip?
  (History preserved in git log either way.)

  [k]eep      keep visible (default)
  [d]elete    archive to git log
```

Reply `k` → plan files preserved. Reply `d` → cleanup commit, recover anytime via `git log --all -- docs/plans/<slug>/`.

---

## Architecture

```
~/your-project/                                ← main repo (base branch)
   └── .claude/worktrees/
       ├── feature-foo/                         ← code worktree (feature/foo)
       ├── feature-bar/                         ← code worktree (feature/bar)
       └── _plans/                              ← plans worktree (plans branch) ⭐
           └── docs/plans/
               ├── feature-foo/_overview.md  + phase-NN.md
               └── feature-bar/_overview.md  + phase-NN.md
```

- `plans` branch is orphan (no parent commits, never merges to base branch)
- All plan reads/writes via `git -C "$PLANS_PATH"` from the `_plans` worktree
- Feature branches stay 100% code → clean squash/rebase, clean PRs
- Push `plans` branch → team + multi-machine sync automatic

---

## Configuration & Adaptations

#### 1. Base branch — automatic

Asked interactively by `/planner setup` — no manual editing needed. Whatever you answer (e.g. `develop`, `main`, `master`) is persisted to `.claude/worktrees/_plans/.planner-config.sh` on the plans branch and sourced by every mode.

> If you installed via `install.sh` (non-plugin), the `<base-branch>` placeholder in `commands/planner.md` is documentation-only — runtime config still takes precedence.

#### 2. Init skill (auto-installed if missing)

The planner auto-invokes a project-context skill in E0.5 before each phase runs. Three scenarios:

**You already have an init skill** (e.g. `init` from another setup):
Set `PLANNER_INIT_SKILL=init` when running `install.sh`, or just leave the `Skill(skill="planner-init")` reference and create your own `planner-init.md`.

**You don't have one (default):**
A generic fallback `planner-init.md` is auto-created at `.claude/commands/planner-init.md`. It reads top-level docs (`CLAUDE.md`, `AGENTS.md`, `README.md`), discovers module-level `AGENTS.md`, and loads package metadata. Good enough to start; replace later if needed.

**Self-healing:**
`/planner setup` re-installs the fallback if it's missing on subsequent runs — useful if someone deletes it.

#### 3. Test command examples

In the phase template, replace examples like:

```
- [ ] T3: write unit test (`<your test command> *NewUseCaseTest*`)
- [ ] T4: `<your build check command>` pass
```

### Optional adaptations

- **Pricing table** — update if you have enterprise discount or use different models. See E10's PRICING dict.
- **Ephemeral worktree pattern** — currently matches `claude/*` and `codex/*`. Add your harness's pattern if different.
- **Token attribution** — depends on Claude Code's JSONL format. May need adjustment for non-Claude-Code harnesses.

---

## How it works (deep dive)

### Branch resolution + 2-commit-push workflow

`/planner run` auto-resolves the branch (5 cases: already on it, on another worktree, ephemeral, has uncommitted work, or missing). Each phase produces 2 commits — code → feature branch, status → plans branch — and **pushes both**. The Stop hook blocks the session from ending if the phase's tasks are ticked but the code commit isn't pushed, or the plans branch isn't updated.

Detailed rules: see `commands/planner.md` § E3 (branch resolution) + § E10 (two-commit-push).

### Cost tracking

Per-phase cost computed by reading the most-recently-modified JSONL in `~/.claude/projects/*/`. Marker-based attribution finds the latest `/planner run` invocation in JSONL and sums tokens after that line.

**Dedupe by `(message_id, usage signature)`** — JSONL contains 2-3 records per turn (response + result snapshots); without dedupe, costs are reported ~1.5-2× over actual.

**Strict marker matching** — content must be a string (skip injected skill-body), `<command-args>` must be non-empty (skip empty-args echoes). If no marker found, emit `?` rather than summing whole file.

Pricing applied per model (read from `message.model` field):
- Opus 4.x: $15 / $75 / $18.75 / $30 / $1.50 (input/output/cache_5m_write/cache_1h_write/cache_read per MTok)
- Sonnet 4.x: $3 / $15 / $3.75 / $6 / $0.30
- Haiku 4.x: $0.80 / $4 / $1 / $1.60 / $0.08

### Cost estimation (P4.5 formula)

Estimates fixed at plan time, calibrated within ±30% of actuals:

```python
cache_size_initial = read_budget + 80_000       # baseline overhead
cache_size_final   = cache_size_initial + (modify_count * 12_000)
turns              = task_count * 5 + 15
output_tokens      = output_lines * 12

cost = (
    cache_size_final * 6 +                      # cache_1h_write (peak)
    avg_cache * turns * 0.5 * 0.30 +            # cache_read (effective)
    output_tokens * 15                          # Sonnet output
) / 1_000_000
```

Baseline calibration:
| Phase profile | est USD |
|---|---|
| Light (4 tasks, 2 files) | ~$0.95 |
| Medium (8 tasks, 4 files) | ~$2.00 |
| Heavy (12 tasks, 6 files) | ~$3.30 |
| Very heavy (16 tasks, 8 files) | ~$4.80 |

---

## FAQ

**Q: How do I install if I don't want to use `gh api` (e.g. local clone or public fork)?**
A:
- **Local clone**: `gh repo clone Thanaphon041/planner-skill /tmp/skill && bash /tmp/skill/install.sh ~/projects/my-app`
- **Public (curl)**: `curl -fsSL https://raw.githubusercontent.com/Thanaphon041/planner-skill/main/install.sh | bash -s -- ~/projects/my-app`

**Q: My project doesn't have an init skill. Should I create one?**
A: No need — installer auto-creates a generic fallback `planner-init.md` if `PLANNER_INIT_SKILL` isn't set. The fallback reads `CLAUDE.md`, `AGENTS.md`, `README.md`, and package metadata (works for Node, Python, Go, Rust, Swift, JVM). Replace it later with something richer if you want.

**Q: Does this work for non-Kotlin/Android projects?**
A: Yes — core mechanics (git worktrees, JSONL parsing, hooks) are language-agnostic. Customize `PLANNER_TEST_CMD` at install time for your stack: `npm test`, `pytest`, `go test ./...`, `cargo test`, etc. Token-per-line and per-file-context constants are calibrated for ~Kotlin-sized files but work approximately for most languages. Adjust `PER_FILE_CONTEXT` in P4.5 if estimates consistently miss for your codebase.

**Q: Can I use this for non-Claude-Code projects?**
A: The skill is Claude Code specific (depends on JSONL format, slash command system, hooks). Concept is portable but implementation needs adaptation.

**Q: What if my team uses `main` (or `master`, `release/*`) as the base branch?**
A: `/planner setup` asks you which branch to fork from and persists it. Nothing to edit manually.

**Q: Why orphan branch instead of just `docs/plans/` in develop?**
A: Plans on develop pollute history (`fix(planner): ...` commits) and CI runs (no need to test plan changes). Orphan branch keeps plans separate, parallel to code timeline. Feature branches stay 100% code.

**Q: Can I skip the `_plans` worktree and just use git commands?**
A: Yes but worktree mounting is more ergonomic. `git -C "$PLANS_PATH"` is simpler than fetching/show-ing files from another branch.

---

## License

MIT — see [LICENSE](LICENSE)

## Credits

Designed iteratively in collaboration with [Claude Code](https://claude.com/claude-code) on a real Kotlin Multiplatform project, then extracted as a portable plugin for any team to adopt.
