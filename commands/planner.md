# SKILL: Planner — Opus plans, Sonnet implements (dedicated `plans` branch)

> **📑 Table of Contents** (line numbers approximate — grep `^# `/`^## ` for exact)
>
> | Section | Line | Use when |
> |---|---|---|
> | ⚡ Router | 42 | First read — dispatch by first arg |
> | Architecture: `plans` branch | 57 | Mental model — orphan branch + worktree |
> | Path resolution | 84 | Resolve `$PLANS_PATH` etc. |
> | **Setup Mode** (`/planner setup`) | 98 | One-time bootstrap (per machine) |
> | **Planning Mode** (`/planner <feature>`) | 222 | Opus designs phases (P0-P8) |
> | • P3 Token budget per phase | 277 | Read-budget rules |
> | • P4.5 Cost estimate formula | 294 | Calibrated ±30% |
> | • P8 Hand-off (HARD STOP) | 524 | Anti auto-implement guard |
> | **Execution Mode** (`/planner run`) | 621 | Sonnet implements one phase |
> | • E0 Verify model = Sonnet | 625 | HARD STOP if Opus |
> | • E0.5 Auto-load init skill | 670 | `Skill(skill="planner-init")` |
> | • E3 Branch resolution (5 cases) | 717 | Auto-stash/pivot/checkout/create |
> | • E10 Per-phase cost compute | 841 | Marker-based JSONL parsing |
> | • E11 Hand-off (+cleanup prompt) | 983 | FEATURE COMPLETE summary |
> | **Status Mode** (`/planner status`) | 1240 | Read-only progress check |
> | **List Mode** (`/planner list`) | 1365 | All plans (active + archived) |
> | **Cleanup Mode** (`/planner cleanup <slug>`) | 1447 | Archive completed plan |
> | **Abort Mode** (`/planner abort <slug>`) | 1513 | Mark plan abandoned ❌ |
> | **Help Mode** (`/planner help`) | 1583 | Mode reference + paths |
> | Rules (immutable) | 1640 | 9 invariants across all modes |
> | Anti-patterns | 1654 | 9 things to avoid |

---

**Eight modes** — routed by first argument:

| Invocation | Who runs | What it does |
|---|---|---|
| `/planner setup` | Any | Bootstrap orphan `plans` branch + mount worktree (per machine) |
| `/planner <feature description>` | Opus 4.7 | Design phases, write to `_plans` worktree, commit to `plans` branch |
| `/planner run [<slug>]` | Sonnet 4.6 | Read plan from `_plans`, implement, 2 commits (code + status) |
| `/planner status [<slug>]` | Any | Read-only progress |
| `/planner list` | Any | List all plans (active + complete + archived) |
| `/planner cleanup <slug>` | Any | Archive completed plan (delete from tip, keep git history) |
| `/planner abort <slug> [<reason>]` | Any | Mark plan ❌ abandoned (keep files) |
| `/planner help` | Any | Mode reference + key paths |

---

## ⚡ Router

Look at `$ARGUMENTS` (first word):

- `setup` → [§ Setup Mode](#setup-mode)
- `run` → [§ Execution Mode](#execution-mode)
- `status` → [§ Status Mode](#status-mode)
- `list` → [§ List Mode](#list-mode)
- `cleanup` → [§ Cleanup Mode](#cleanup-mode)
- `abort` → [§ Abort Mode](#abort-mode)
- `help` → [§ Help Mode](#help-mode)
- empty / anything else → [§ Planning Mode](#planning-mode)

---

## Architecture: dedicated `plans` branch

**Problem with branch-based plans (old design):**
- Plan locked to feature branch → switch worktree = plan gone
- Auto-named worktrees (`claude/<random>`) get re-created often → plan disappears
- E3 strict-match break

**Solution:** Plans live on a separate **orphan `plans` branch**, mounted as a sibling worktree to all feature worktrees:

```
<your-project-path>/                    ← main repo (<base-branch>)
   └── .claude/worktrees/
       ├── feature-foo/                               ← code worktree (feature/foo)
       ├── feature-bar/                               ← code worktree (feature/bar)
       └── _plans/                                    ← plans worktree (plans branch)  ⭐
           └── docs/plans/
               ├── feature-foo/_overview.md  + phase-NN.md
               └── feature-bar/_overview.md  + phase-NN.md
```

- `plans` branch is **orphan** — no commits in common with develop. CI ignores it.
- All plan reads/writes go through `_plans` worktree
- Feature branches stay 100% code, no plan files
- Push `plans` branch → team + multi-machine sync

---

## Path + config resolution (used in all modes)

Every mode must resolve these paths and load runtime config first:

```bash
MAIN_REPO=$(git worktree list | head -1 | awk '{print $1}')
PLANS_WORKTREE="$MAIN_REPO/.claude/worktrees/_plans"
PLANS_DIR="$PLANS_WORKTREE/docs/plans"

# Load runtime config written by /planner setup (base branch).
# Falls back to safe defaults if config is missing (legacy installs).
PLANNER_CONFIG="$PLANS_WORKTREE/.planner-config.sh"
[[ -f "$PLANNER_CONFIG" ]] && source "$PLANNER_CONFIG"
PLANNER_BASE_BRANCH="${PLANNER_BASE_BRANCH:-<base-branch>}"   # e.g. develop, main
```

**Sanity check:** if `$PLANS_WORKTREE/.git` does not exist → user hasn't run setup → STOP and tell them to run `/planner setup`

**Language note:** Sonnet/Opus naturally mirrors the user's language (Thai prompts → Thai responses, English prompts → English responses). No language config needed. **Always keep English regardless of user's language:** commit messages, code, file contents, branch names, plan markdown bodies — this keeps git history consumable by international teams.

---

# Setup Mode (`/planner setup`)

**Run as any model.** Once per machine (or once per project if it's the first machine on the team).

Setup performs 8 steps:
1. **SU0** — Ask user for base branch (interactive prompt)
2. **SU1** — Detect existing state (worktree / local branch / remote branch)
3. **SU2-SU5** — Mount, fetch+mount, or bootstrap based on detected state
4. **SU6** — Write `.planner-config.sh` (base branch) to plans branch
5. **SU7** — Ensure init skill is installed (idempotent self-heal)
6. **SU8** — Echo summary

## SU0: Ask user for base branch

If `$PLANS_WORKTREE/.planner-config.sh` exists already (another machine on the team committed it before), load it and ask user whether to keep or override. Otherwise ask fresh.

```bash
MAIN_REPO=$(git worktree list | head -1 | awk '{print $1}')
PLANS_PATH="$MAIN_REPO/.claude/worktrees/_plans"
EXISTING_CONFIG="$PLANS_PATH/.planner-config.sh"

if [[ -f "$EXISTING_CONFIG" ]]; then
    source "$EXISTING_CONFIG"
    echo "Found existing config:"
    echo "  Base branch:  $PLANNER_BASE_BRANCH"
    echo ""
    echo "Keep this value? (Y/n)"
    # If yes → skip to SU1
    # If no → fall through to interactive prompt below
fi
```

**Interactive prompt (when no config or user wants to override):**

```
Which branch should /planner branch off from when planning new features?
    Common choices: develop / main / master
    Default: develop
    Your answer: _
```

After answer collected, store in shell variable for SU6 to write:

```bash
PLANNER_BASE_BRANCH="<user's answer, e.g. develop>"
```

Validate before continuing:
- `PLANNER_BASE_BRANCH` must exist on `origin/`: `git ls-remote --heads origin "$PLANNER_BASE_BRANCH" | grep -q .` — if not, ask again

> **Why no language question:** Sonnet/Opus already mirrors the user's prompt language naturally (Thai questions → Thai responses; English → English). Adding a config knob for this is over-engineering. Artifacts (commit messages, code, plan files, branch names) stay in English regardless — that's documented as a rule in Path resolution above.

## SU1: Detect state

```bash
# Check these 4 things in parallel:
ls "$PLANS_PATH/.git" 2>/dev/null && echo "WORKTREE_EXISTS" || echo "WORKTREE_MISSING"
git -C "$MAIN_REPO" ls-remote --heads origin plans | grep -q plans && echo "REMOTE_EXISTS" || echo "REMOTE_MISSING"
git -C "$MAIN_REPO" show-ref --verify --quiet refs/heads/plans && echo "LOCAL_EXISTS" || echo "LOCAL_MISSING"
```

## SU2: 4 cases

| WORKTREE | LOCAL branch | REMOTE branch | Action |
|---|---|---|---|
| EXISTS | EXISTS | EXISTS | ✅ Already setup. echo state + `git -C "$PLANS_PATH" pull --ff-only` to sync |
| MISSING | MISSING | EXISTS | **fetch + mount** (case: another machine already set up) |
| MISSING | MISSING | MISSING | **bootstrap** (case: first ever setup of this project) |
| MISSING | EXISTS | * | **mount only** (case: branch exists but not mounted) |

## SU3: Action — Mount only (LOCAL exists, no worktree)

```bash
git -C "$MAIN_REPO" worktree add "$PLANS_PATH" plans
```

## SU4: Action — Fetch + mount (REMOTE exists)

```bash
git -C "$MAIN_REPO" fetch origin plans:plans
git -C "$MAIN_REPO" worktree add "$PLANS_PATH" plans
```

## SU5: Action — Bootstrap (first ever)

```bash
# Create detached worktree first (does NOT modify main repo's branch)
git -C "$MAIN_REPO" worktree add --detach "$PLANS_PATH" HEAD

# Convert to orphan branch in plans worktree only
cd "$PLANS_PATH"
git checkout --orphan plans
git rm -rf .                                          # clear all files
mkdir -p docs/plans
cat > docs/plans/.gitkeep <<EOF
This branch holds planner state for the /planner skill.
Created automatically by /planner setup.
Do not merge into $PLANNER_BASE_BRANCH — this branch is orphan and code-free.
EOF
git add docs/plans/.gitkeep
git commit -m "init: planner state branch (orphan)"
git push -u origin plans
```

> **DO NOT:** run `git checkout --orphan plans` directly in the main repo — it will wipe the main repo's working tree

## SU6: Write `.planner-config.sh` to plans branch

Persist the value collected in SU0 so every subsequent invocation (run/status/list/etc.) can source it.

```bash
cat > "$PLANS_PATH/.planner-config.sh" <<EOF
# Auto-generated by /planner setup. Edit value then re-run /planner setup
# (or edit + commit on plans branch directly) to update.
PLANNER_BASE_BRANCH="$PLANNER_BASE_BRANCH"
EOF

git -C "$PLANS_PATH" add .planner-config.sh
# Only commit if changed (avoid noisy commits when re-running setup with same values)
if ! git -C "$PLANS_PATH" diff --cached --quiet; then
    git -C "$PLANS_PATH" commit -m "config: base_branch=$PLANNER_BASE_BRANCH"
    git -C "$PLANS_PATH" push origin plans
    echo "✅ Config written: base_branch=$PLANNER_BASE_BRANCH"
else
    echo "✅ Config unchanged"
fi
```

> **Why commit:** the config travels with the plans branch. Other machines that run `/planner setup` will see the existing config in SU0 and can keep or override.

## SU7: Ensure init skill exists (idempotent)

`/planner run` E0.5 invokes an init skill (`Skill(skill="planner-init")` by default, or whatever was wired during install). If the skill file is missing, install the bundled fallback so phase execution doesn't break.

```bash
# Resolve which init skill the planner expects
INIT_SKILL_NAME=$(grep -oE 'Skill\(skill="([^"]+)"\)' "$MAIN_REPO/.claude/commands/planner.md" \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

INIT_SKILL_FILE="$MAIN_REPO/.claude/commands/${INIT_SKILL_NAME}.md"

if [[ -z "$INIT_SKILL_NAME" ]]; then
  echo "⚠️  No init skill referenced in planner.md — skipping"
elif [[ -f "$INIT_SKILL_FILE" ]]; then
  echo "✅ Init skill present: $INIT_SKILL_NAME"
else
  echo "⚠️  Init skill '$INIT_SKILL_NAME' missing — installing fallback"
  # Write the fallback init skill content (kept inline so /planner setup
  # works even if this skill was installed without the examples/ folder).
  cat > "$INIT_SKILL_FILE" <<'INITEOF'
# SKILL: Planner Init — Load Project Context

Generic project-context loader. Auto-invoked by `/planner run` (E0.5)
before phase execution. Replace this with a richer init for your project
when ready (just keep the same filename).

## Steps

1. **Project root:** `git rev-parse --show-toplevel`
2. **Read top-level docs (if present):** `CLAUDE.md`, `AGENTS.md`,
   `README.md` (first 100 lines), `ARCHITECTURE.md`, `docs/architecture.md`
3. **Discover module AGENTS:**
   `find . -maxdepth 3 -name AGENTS.md -not -path '*/node_modules/*' -not -path '*/.git/*'`
4. **Read package metadata** (whichever exists): `package.json`, `Cargo.toml`,
   `pyproject.toml`, `go.mod`, `build.gradle.kts`, `Package.swift`, `pom.xml`
5. **Quick git status:** `git status --short` + current branch
6. **Echo:** `✅ Project context loaded: <package-name> · branch=<current>`

## Constraints

- Keep reads ≤ 5k tokens — heavy context belongs in the phase's `Files to read`
- Do NOT run tests/builds (that's the phase's job)
- Skip files that don't exist silently
INITEOF
  echo "   → installed at $INIT_SKILL_FILE"
fi
```

## SU8: Verify + echo

```bash
echo ""
echo "✅ Planner setup complete"
echo "   Plans worktree: $PLANS_PATH"
echo "   Branch:         plans (orphan)"
echo "   Remote:         origin/plans (synced)"
echo "   Base branch:    $PLANNER_BASE_BRANCH"
echo "   Init skill:     ${INIT_SKILL_NAME:-<none>}"
echo ""
echo "Next: use /planner <feature> to create your first plan"
```

---

# Planning Mode (`/planner <feature>`)

**Run as Opus 4.7.** If running on Sonnet → tell user to switch model.

## P0: Pre-check — `_plans` worktree ready

```bash
MAIN_REPO=$(git worktree list | head -1 | awk '{print $1}')
PLANS_PATH="$MAIN_REPO/.claude/worktrees/_plans"
[[ -e "$PLANS_PATH/.git" ]] || { echo "STOP: run /planner setup first"; exit; }

# Sync first — avoid outdated state
git -C "$PLANS_PATH" pull --ff-only origin plans 2>&1
```

## P1: Confirm scope + auto-create branch (current feature worktree)

Ask user only 2 things (keep it short): **slug** + **type** (default `feature`). Never ask "are you on the right branch?" — planner creates `<type>/<slug>` from `origin/<base-branch>` itself (in-place rebrand) if needed.

| State | Action |
|---|---|
| cwd = main repo | STOP + tell user to create a feature worktree first |
| dirty working tree | STOP + ask user to commit/stash |
| cwd = worktree, branch already = `<type>/<slug>` (real, not auto-named) | ✅ use as-is — skip rebrand |
| cwd = worktree, branch = `<base-branch>` / `main` | STOP — refuse to plan on protected branch |
| cwd = worktree, branch = `claude/<random>` (auto-named) **or** any other clean local branch | **AUTO-REBRAND IN PLACE** — `git branch -m <type>/<slug>` (rename current branch; preserves any prep commits). Silent. No prompt. |
| cwd = worktree, detached HEAD | `git checkout -b <type>/<slug>` (creates from current commit; no rebase/discard). Silent. |

**Concrete steps** (do these silently, in order):
```bash
SLUG="<feature-slug>"          # confirmed with user
TYPE="feature"                 # default; override only if obviously fix/refactor/chore
NEW_BRANCH="$TYPE/$SLUG"

CURRENT=$(git branch --show-current)
if [[ "$CURRENT" == "$NEW_BRANCH" ]]; then
    : # already on it; no-op
elif [[ -z "$CURRENT" ]]; then
    git checkout -b "$NEW_BRANCH"        # detached HEAD case
else
    git branch -m "$NEW_BRANCH"          # rename in place — keeps history + prep commits
fi
```

**Why rename-in-place over `checkout -b ... origin/<base-branch>`**: if user has prep commits on the auto-named branch, recreating from `origin/<base-branch>` would silently discard them. Rename preserves work. If you want a fresh slate, the user can rebase or reset — that's their call, not the planner's.

**`<type>` defaults to `feature`.** Only ask if the feature is clearly a fix/refactor/chore. Don't ask "are you sure?" — just pick and proceed.

> **Removed Mode B** (new sibling worktree) — `_plans` branch + per-feature `_plans/docs/plans/<slug>/` directory mean plans are no longer locked to feature worktrees, so spawning a new sibling worktree for the plan adds zero value. If user genuinely wants a separate worktree they can `git worktree add` themselves; planner stays in current cwd.

## P2: Explore codebase

Read `AGENTS.md`, `CLAUDE.md`, `wiki/index.md` (if present), module-level AGENTS, existing code/tests.
**Rule:** never hallucinate paths — every file referenced in the plan must be verified to exist.

## P3: Token budget per phase (≤ 60k read budget)

| Content | tokens/line |
|---|---|
| Generic source code | ~8 |
| Markdown | ~12 |
| JSON/config | ~6 |

If read > 40k → split phase. If output code > 500 lines → split.

## P4: Design phases (3-7 phases sweet spot)

- 1 phase = 1 logical unit = 1 commit
- Each independently verifiable (test/build/manual)
- Order by dependency
- `Depends on:` should reference artifacts (file/symbol from previous commits) — do NOT require reading other phase files

## P4.5: Cost estimate per phase (calibrated against actuals — should land within ±30%)

Use this formula to compute estimated tokens + USD per phase, written into the Costs table of the overview at plan creation time. **Estimates are FIXED at plan time — never recalibrated mid-flight** (user expects estimates to be stable across the feature lifecycle).

**Calibration:** old formula (turns=15, cache=50k) underestimated by ~5×. New formula models 3 things the old one missed:
1. **Context grows during phase** — tool outputs (Read/Bash/Grep results) accumulate
2. **Test/compile cycles** — each fail adds 5-10 turns + stack trace tokens
3. **Per-task turn count** — Sonnet typically takes ~5 turns per task (not 15 turns total)

```python
# Per phase, Sonnet 4.6 (default execution model)
# Inputs from phase template:
read_budget         # tokens, sum of "Files to read" estimated tokens (P3)
task_count          # count of T1..TN in "Tasks" checklist
output_lines        # from "Estimated output" hint (code + tests)
modify_count        # count of files in "Files to create / modify"

# Derived: cache size grows during phase
BASE_OVERHEAD = 80_000        # CLAUDE.md auto-inject + system prompt + init skill
PER_FILE_CONTEXT = 12_000     # each modified file → ~12k context (read + edit + test)

initial_cache = read_budget + BASE_OVERHEAD                  # at start of phase
final_cache   = initial_cache + (modify_count * PER_FILE_CONTEXT)  # at end
avg_cache     = (initial_cache + final_cache) / 2            # for cache_read pricing

# Turn count: ~5 turns per task + baseline (init load, plan read, commit, etc.)
turns = task_count * 5 + 15

# Output: Sonnet narrates + edits multiple times → ~1.5× the spec
output_tokens = output_lines * 12

# Sonnet 4.6 pricing
cost_usd = (
    final_cache * 6 +                          # cache_1h_write (peak size, written once)
    avg_cache * turns * 0.5 * 0.30 +           # cache_read (avg size × ~50% of turns hit cache)
    output_tokens * 15 +                       # output tokens
    1000 * 3                                   # fresh input (~negligible)
) / 1_000_000

# Tokens (display)
est_tokens = final_cache + (avg_cache * turns * 0.5) + output_tokens
```

**Sanity check baseline (calibrated against real phase actuals):**

| Phase profile | read | tasks | output | modify | est tokens | est USD |
|---|---|---|---|---|---|---|
| Light (small fix) | 10k | 4 | 80 | 2 | ~1.6M | ~$0.95 |
| Medium (typical) | 25k | 8 | 200 | 4 | ~3.5M | ~$2.00 |
| Heavy (multi-module) | 40k | 12 | 350 | 6 | ~5.5M | ~$3.30 |
| Very heavy (refactor) | 60k | 16 | 500 | 8 | ~8.0M | ~$4.80 |

**Caveat:** test/compile fail cycles add 10-30% on top. Estimates ±30% are realistic. If actuals consistently exceed est by >50%, the phase was too big — split next time.

## P5: Write `_overview.md` to `_plans` worktree

```bash
SLUG="<feature-slug>"
mkdir -p "$PLANS_PATH/docs/plans/$SLUG"
# Write _overview.md to "$PLANS_PATH/docs/plans/$SLUG/_overview.md"
```

**Template:**

```markdown
# Plan: <Feature Name>

**Created:** YYYY-MM-DD by Opus 4.7
**Code branch:** <type>/<slug>     ← branch created by P1; E3 will silent-retarget if executor session is on a different branch
**Total phases:** N

## Goal
<2-4 lines>

## Non-goals
<scope guard>

## Status

| # | Phase | Status | Files | Note |
|---|---|---|---|---|
| 01 | <name> | ⬜ pending | `phase-01.md` | - |

**Legend:** ⬜ pending · 🟡 in-progress · 🟠 blocked · ✅ done · ❌ failed

## Decisions Log
- **D1:** ... — **Why:** ... — **Affects:** phase X

## Out-of-scope spotted
- ...

## Costs

> Estimates set by /planner using P4.5 formula. Actuals filled in by /planner run.
> Sonnet 4.6 pricing assumed. Estimate ±30% — calibrated against real phase actuals.

| Phase | Tokens | USD | Model | Note |
|---|---|---|---|---|
| 01 | ~3.5M (est) | ~$2.00 (est) | sonnet | medium phase |
| 02 | ~5.5M (est) | ~$3.30 (est) | sonnet | depends on 01 |
| 03 | ~3.5M (est) | ~$2.00 (est) | sonnet | |

**Total estimate: ~12.5M tokens · ~$7.30**
```

## P6: Write each `phase-NN.md` to `_plans` worktree

Path: `$PLANS_PATH/docs/plans/<slug>/phase-NN.md`

Template includes: Status, Depends on, Estimated read budget, Goal, Context, Files to read, Files to create/modify, Tasks, Acceptance criteria, Decisions reference, Notes/Gotchas

## P7: Commit + push to `plans` branch

```bash
git -C "$PLANS_PATH" add "docs/plans/$SLUG/"
git -C "$PLANS_PATH" commit -m "plan: <feature-name>

N phases (~Xk total read budget)
Code branch: <type>/<slug>
"
git -C "$PLANS_PATH" push origin plans
```

> **No commit in feature worktree** — feature branch stays clean, plan lives on plans branch only

## P8.0: Compute planning session cost (Opus)

Before building the hand-off message — capture the cost Opus used during planning in this session. Mark the start at the "/planner <feature>" invocation (planning mode = first arg is NOT run/status/setup):

```bash
read PLAN_TOKENS PLAN_COST_USD <<<"$(python3 - <<'PY'
import os, json, glob, re

PRICING = {
    "claude-opus-4":     (15.00, 75.00, 18.75, 30.00, 1.50),
    "claude-sonnet-4":   ( 3.00, 15.00,  3.75,  6.00, 0.30),
    "claude-haiku-4":    ( 0.80,  4.00,  1.00,  1.60, 0.08),
    "claude-3-5-sonnet": ( 3.00, 15.00,  3.75,  6.00, 0.30),
    "claude-3-5-haiku":  ( 0.80,  4.00,  1.00,  1.60, 0.08),
    "claude-3-opus":     (15.00, 75.00, 18.75, 30.00, 1.50),
}
def rates(m):
    for p, r in PRICING.items():
        if m.startswith(p): return r
    return PRICING["claude-sonnet-4"]

home = os.path.expanduser("~")
all_jsonls = glob.glob(f"{home}/.claude/projects/*/*.jsonl")
if not all_jsonls:
    print("0 0"); raise SystemExit
latest = max(all_jsonls, key=os.path.getmtime)

with open(latest) as f:
    lines = f.readlines()

# Find LATEST planning-mode invocation.
# Strict matching to avoid false positives:
#   1. Content must be a STRING (list-content = injected skill body — skip)
#   2. <command-args> must be present and NON-EMPTY
#   3. first_arg NOT in (run/status/setup)
# If no valid marker → emit "?" (better than summing whole file).
start_idx = None
for i, line in enumerate(lines):
    try:
        obj = json.loads(line)
        if obj.get("type") != "user": continue
        c = obj.get("message", {}).get("content", "")
        if not isinstance(c, str): continue  # injected list-content (e.g. skill body)
        if not re.search(r"<command-name>/?planner</command-name>", c):
            continue
        am = re.search(r"<command-args>([^<]*)</command-args>", c)
        if not am: continue
        args = am.group(1).strip()
        if not args: continue  # empty args — router/echo, not real planning
        first_arg = args.split()[0]
        if first_arg in ("run", "status", "setup"): continue
        start_idx = i  # real planning invocation

if start_idx is None:
    print("? ?"); raise SystemExit  # caller renders "?"

# Dedupe by (message_id, usage signature) — JSONL has duplicate usage
# records per turn, causing ~1.5-2× overcounting if not deduped.
seen = set()
total_tokens = 0
total_cost = 0.0
for line in lines[start_idx:]:
    try:
        obj = json.loads(line)
        msg = obj.get("message", {})
        m = msg.get("model")
        u = msg.get("usage")
        if not (m and isinstance(u, dict)): continue
        mid = msg.get("id") or obj.get("uuid")
        key = (mid, json.dumps(u, sort_keys=True))
        if key in seen: continue
        seen.add(key)
        in_t  = u.get("input_tokens", 0)
        out_t = u.get("output_tokens", 0)
        cr_t  = u.get("cache_read_input_tokens", 0)
        cc    = u.get("cache_creation") or {}
        c5_t  = cc.get("ephemeral_5m_input_tokens", 0)
        c1_t  = cc.get("ephemeral_1h_input_tokens", 0)
        if not (c5_t or c1_t):
            c5_t = u.get("cache_creation_input_tokens", 0)
        r = rates(m)
        total_tokens += in_t + out_t + cr_t + c5_t + c1_t
        total_cost += (in_t*r[0] + out_t*r[1] + c5_t*r[2] + c1_t*r[3] + cr_t*r[4]) / 1_000_000
    except: pass
print(f"{total_tokens} {total_cost:.2f}")
PY
)"
case "$PLAN_TOKENS" in ""|"0"|"?") PLAN_TOKENS="?" ;; esac
case "$PLAN_COST_USD" in ""|"0.00"|"?") PLAN_COST_USD="?" ;; esac
```

Insert into overview's Costs table as a special row:

```markdown
## Costs

| Phase | Tokens | USD | Model | Note |
|---|---|---|---|---|
| Plan  | ~<PLAN_TOKENS> | $<PLAN_COST_USD> | opus | planning session |
| 01    | ~3.5M (est)    | ~$2.00 (est)     | sonnet | |
| 02    | ...            | ...              | sonnet | |
```

→ E11's total at completion includes the "Plan" row too → total cost = planning + all phases

## P8: Hand-off message — **HARD STOP after this output**

> 🛑 **CRITICAL:** after outputting this step's hand-off message — the turn ends immediately. **DO NOT implement phase 01 or anything else in this session.**
>
> Reason: the current session has loaded Opus planning context (~150k+ tokens) → if you implement a phase here = using Opus model + bloated context = **~5× more expensive** than starting a fresh Sonnet session.
>
> **If user replies with short words** like `"A"`, `"B"`, `"OK"`, `"go"`, `"start"`, `"yes"`, or any short affirmative in any language — **DO NOT proceed to implement**. Reply briefly:
>
> > "Plan saved. To start phase 01, please type these yourself:
> > ```
> > /clear
> > (switch model to Sonnet 4.6 in UI)
> > /planner run
> > ```
> > I cannot trigger `/clear` from this session (Claude Code limitation). Once you type those commands, the planner skill picks up phase 01 fresh."
>
> **Why the user must type it themselves:**
> - `/clear` is a Claude Code built-in — the skill cannot invoke it via the Skill tool
> - Switching models = a UI action — the skill cannot control it
> - Fresh session / cleared context = Sonnet doesn't carry Opus's planning bloat → cost stays on target



```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  PLAN SAVED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Slug          <slug>
  Code branch   <type>/<slug>
  Plans branch  plans @ <hash>

──────────────────────────────────────────────
📋  PHASES (N)
──────────────────────────────────────────────

  01  <name>
      read ~Xk  · output ~Y lines  · est ~$2.00

  02  <name>
      read ~Xk  · output ~Y lines  · est ~$3.30

  ...

──────────────────────────────────────────────
💸  PLANNING COST (this Opus session)
──────────────────────────────────────────────

  Tokens   ~<PLAN_TOKENS>
  USD      $<PLAN_COST_USD>  (Opus model)

  Planning is one-time per feature.
  Phase execution will use Sonnet (cheaper).

──────────────────────────────────────────────
💰  ESTIMATED PHASE TOTAL (forward)
──────────────────────────────────────────────

  ~<TOTAL_TOKENS> tokens  ·  ~$<TOTAL_USD>
  (Sonnet 4.6 assumed, ±30% range — calibrated)

──────────────────────────────────────────────
🧮  EXPECTED FEATURE COST
──────────────────────────────────────────────

  Plan + N phases  ≈  $<PLAN_COST_USD> + $<TOTAL_USD>  =  $<GRAND_TOTAL>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
👉  START PHASE 01 — Pick one:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ┌──────────────────────────────────────────┐
  │  Option A — Same session  (faster ~30s) │
  └──────────────────────────────────────────┘

      /clear
      → switch model to Sonnet 4.6 (UI)
      /planner run

      ⚠️  Cache reset on Opus→Sonnet transition.
         No $ saving on first phase, but saves time.
         Phases 02+ via Option A save ~$0.30 each.

  ┌──────────────────────────────────────────┐
  │  Option B — New session  (clean slate)  │
  └──────────────────────────────────────────┘

      1.  Close Claude Code
      2.  Open at any feature worktree, pick Sonnet 4.6
      3.  /planner run

  Both auto-load project context (init skill) internally.
  E3 auto-handles branch mismatch (rebrand/checkout/stash).
```

---

# Execution Mode (`/planner run`)

**Run as Sonnet 4.6.** Auto-pickup current phase

## E0: Verify model = Sonnet (HARD STOP if Opus)

Before doing anything — detect the current session's model from JSONL. Phase execution is designed for Sonnet 4.6 (~5× cheaper than Opus). Running on Opus = bug.

```bash
DETECTED_MODEL=$(python3 - <<'PY'
import os, json, glob
home = os.path.expanduser("~")
all_jsonls = glob.glob(f"{home}/.claude/projects/*/*.jsonl")
if not all_jsonls:
    print(""); raise SystemExit
latest = max(all_jsonls, key=os.path.getmtime)
last_model = ""
with open(latest) as f:
    for line in f:
        try:
            obj = json.loads(line)
            m = obj.get("message", {}).get("model")
            if m and not m.startswith("<"):
                last_model = m
        except: pass
print(last_model)
PY
)

if [[ "$DETECTED_MODEL" == claude-opus-* ]]; then
    cat <<EOF
🛑 STOP — /planner run requires Sonnet 4.6, current session = $DETECTED_MODEL

Phase execution on Opus = ~5× cost vs Sonnet (Opus: \$15/\$75 vs
Sonnet: \$3/\$15 per MTok). Switch model first:

  1. /clear                         (drop Opus context)
  2. Switch model to Sonnet 4.6 in Claude Code UI
  3. /planner run                   (re-invoke this skill on Sonnet)

If you intentionally want Opus for execution (e.g., very complex phase),
override by setting env var: PLANNER_ALLOW_OPUS=1 then re-run.
EOF
    [[ "${PLANNER_ALLOW_OPUS:-}" == "1" ]] || exit 1
fi
```

> Note: if it's a fresh session (JSONL empty or no previous assistant turns) → DETECTED_MODEL = "" → skip check and proceed (assume Sonnet based on user's choice in the launcher).

## E0.5: Auto-load project context

Before E1 — if project context isn't already loaded (e.g. user did `/clear` then `/planner run` without `/init`), automatically invoke the project's init skill via the Skill tool:

```
Skill(skill="<your-init-skill>")
```

The placeholder `<your-init-skill>` is replaced at install time:
- If user passed `PLANNER_INIT_SKILL=foo` → wired to their existing `foo` skill
- Otherwise → installer drops in a fallback `planner-init` skill (`.claude/commands/planner-init.md`) and wires `Skill(skill="planner-init")`

The init skill loads project-level docs (CLAUDE.md, AGENTS.md, package metadata) so Sonnet has a foundation before phase execution.

**Heuristic for "should I call init?":** if the session already has AGENTS.md content loaded (Sonnet can "see" architecture rules + module map in context), skip. Otherwise → invoke the init skill.

Simpler approach: **always invoke** — init is idempotent, files cached, cost ≈ negligible (~$0.01) on repeat. But you can still skip if you're confident context is loaded.

## E1: Verify env (HARD STOP if mismatch)

```bash
MAIN_REPO=$(git worktree list | head -1 | awk '{print $1}')
PLANS_PATH="$MAIN_REPO/.claude/worktrees/_plans"
CWD_ROOT=$(git rev-parse --show-toplevel)
BRANCH=$(git branch --show-current)
```

| Bad state | Action |
|---|---|
| cwd = main repo | STOP — never run in the main repo |
| `_plans` worktree missing | STOP — run `/planner setup` first |
| branch = `<base-branch>`/`main` | STOP — switch to a feature branch |
| dirty working tree | warn + ask |

## E2: Detect plan

```bash
git -C "$PLANS_PATH" pull --ff-only origin plans 2>&1   # sync to latest first
find "$PLANS_PATH/docs/plans" -mindepth 1 -maxdepth 1 -type d | sort
```

| Result | Action |
|---|---|
| 0 plans | STOP — tell user to create a plan first (`/planner <feature>`) |
| 1 plan | use that one |
| ≥ 2 plans | if user passed a slug as arg → use it; else show list and ask user to pick |

## E3: Strict branch lock — plan target = source of truth (auto-fix where possible)

**Goal:** plan is strictly bound to the Code branch recorded at plan creation. No silent retargeting. If user is on the wrong branch → skill auto-fixes every case it can safely.

**Mental model:** plan target = sticky pointer. Once the plan declares its code branch is X, running `/planner run` must end up executing on X. The skill handles checkout/stash/branch-create itself without asking.

### Inputs (compute first)

```bash
PLAN_BRANCH=$(grep -i "^\\*\\*Code branch:\\*\\*" "$OVERVIEW" | sed -E 's/.*: *`?([^`]+)`?.*/\1/' | tr -d ' ')
CURRENT=$(git branch --show-current)
CURRENT_WT=$(git rev-parse --show-toplevel)

# Where (if anywhere) is PLAN_BRANCH currently checked out?
PLAN_WT=$(git -C "$MAIN_REPO" worktree list --porcelain | awk -v t="refs/heads/$PLAN_BRANCH" '
  /^worktree / { wt = $2 }
  /^branch / && $2 == t { print wt; exit }
')

# Local + remote existence of PLAN_BRANCH
git show-ref --verify --quiet "refs/heads/$PLAN_BRANCH"             && PLAN_LOCAL=1  || PLAN_LOCAL=0
git ls-remote --heads origin "$PLAN_BRANCH" 2>/dev/null | grep -q . && PLAN_REMOTE=1 || PLAN_REMOTE=0

# "Ephemeral" current = auto-named harness worktree, no commits, clean
# Used ONLY to decide whether auto-checkout is safe in Case 3
EPHEMERAL=0
if [[ "$CURRENT" =~ ^(claude|codex)/ ]] \
   && git merge-base --is-ancestor HEAD "origin/$PLANNER_BASE_BRANCH" 2>/dev/null \
   && [[ -z "$(git status --porcelain)" ]]; then
    EPHEMERAL=1
fi
```

### Decision tree (strict + auto-fix)

| # | Condition | Action |
|---|---|---|
| 0 | `PLAN_BRANCH` empty | ✅ proceed; set field to `CURRENT` on next status commit (legacy plan) |
| 1 | `PLAN_BRANCH == CURRENT` | ✅ proceed silently |
| 2 | mounted on another worktree (`PLAN_WT != CURRENT_WT`) | **AUTO-TAKEOVER** — pivot the other worktree to a temp branch, then adopt PLAN_BRANCH here:<br>1. If `git -C $PLAN_WT status --porcelain` non-empty → `git -C $PLAN_WT stash push -u -m "auto-stash from $PLAN_WT before takeover [<epoch>]"`<br>2. `git -C $PLAN_WT checkout -B "auto-pivoted/<PLAN_BRANCH>-<epoch>" origin/<base-branch>` (switch the other worktree's branch, **without** removing the filesystem → preserves .gradle/.idea/build/)<br>3. `git fetch origin <PLAN_BRANCH>` (if remote)<br>4. `git checkout <PLAN_BRANCH>` (current worktree adopts)<br>5. echo:<br>`ℹ️ Took over <PLAN_BRANCH> (was on <PLAN_WT>)`<br>`   Other worktree pivoted to: auto-pivoted/<PLAN_BRANCH>-<epoch>`<br>`   Stash (if any): cd <PLAN_WT> && git stash list \| grep <epoch>`<br>`   Migrate back: cd <PLAN_WT> && git checkout <PLAN_BRANCH> (after this session)` |
| 3 | not mounted, exists local/remote, `EPHEMERAL=1` | **AUTO-CHECKOUT**: `git fetch origin <PLAN_BRANCH>` (if remote) → `git checkout <PLAN_BRANCH>` → echo `ℹ️ Switched to <PLAN_BRANCH> (was ephemeral)` → ✅ proceed |
| 4 | not mounted, exists local/remote, `EPHEMERAL=0` (current has work) | **AUTO-STASH + CHECKOUT**:<br>`STASH_REF=$(git stash create "auto-stash before /planner run [<TIMESTAMP>]")` (create stash without touching working tree)<br>`git stash store -m "auto-stash before /planner run [<TIMESTAMP>] from <CURRENT>" "$STASH_REF"`<br>`git checkout . && git clean -fd` (clear working tree)<br>`git fetch origin <PLAN_BRANCH>` (if remote)<br>`git checkout <PLAN_BRANCH>`<br>echo:<br>`ℹ️ Auto-stashed work on <CURRENT> and switched to <PLAN_BRANCH>`<br>`   Stash: stash@{0} "auto-stash before /planner run [<TIMESTAMP>]"`<br>`   To resume work on <CURRENT>: git checkout <CURRENT> && git stash pop`<br>→ ✅ proceed |
| 5 | branch doesn't exist anywhere | **AUTO-CREATE FROM BASE**:<br>`git fetch origin <base-branch>`<br>`git checkout -b <PLAN_BRANCH> origin/<base-branch>`<br>echo `ℹ️ Created <PLAN_BRANCH> from origin/<base-branch>` → ✅ proceed |

### Auto-stash safety (Case 4)

- Use `git stash create` + `git stash store` instead of `git stash push` to:
  - Avoid triggering pre-stash hooks
  - Avoid touching working tree during creation
  - Get a deterministic SHA for the stash
- Follow with `git checkout .` + `git clean -fd` to clean the working tree before checkout
- Stash message includes `[<TIMESTAMP>]` (epoch seconds) → easy to search in `git stash list`
- **No auto-pop** at end of phase — user decides (may conflict if phase touched the same files)
- Recovery hint is also printed in E11 hand-off if a stash is pending

### Why strict + auto

- **Predictability:** plan declares branch X once, every `/planner run` ends up on X — no silent retarget
- **No friction:** Cases 4-5 auto-fix → user types nothing
- **Case 2 unavoidable:** real git constraint — but skill outputs a 2-line copy-paste recovery
- **Stash safety:** explicit message + manual pop → user controls recovery

### What changed vs. previous "STOP + instruct" design

- ✅ Case 4 → AUTO-STASH + CHECKOUT (was STOP)
- ✅ Case 5 → AUTO-CREATE from <base-branch> (was STOP + 2 options)
- ✅ Case 2 → AUTO-TAKEOVER via pivot (was STOP + copy-paste)
- ❌ Still no silent retarget (plan target stays sticky)
- ❌ Still no asking the user (deterministic for every case)
- 🎯 **Zero user action** — run `/planner run` from any worktree; you always end up on `<PLAN_BRANCH>`

### Auto-takeover safety (Case 2)

- Uses `checkout -B "auto-pivoted/..."` instead of `worktree remove` → does **not** delete the other worktree's filesystem. Build cache, IDE state, untracked files stay intact.
- Other worktree's tracked changes → stashed before pivot (descriptive message + epoch)
- Branch name `auto-pivoted/<orig>-<epoch>` makes it easy to find which branch was auto-rotated
- Recovery: cd back to the other worktree, checkout PLAN_BRANCH (after the current session has pivoted away)
- **Caveat:** if another Claude session is running on the other worktree concurrently → its branch gets switched under it. Users running parallel sessions accept this. (Multi-session use case is rare; auto-takeover prioritizes the session that explicitly invoked `/planner run`.)

## E4: Find current phase

Read `$PLANS_PATH/docs/plans/<slug>/_overview.md` Status table → first row that isn't ✅

- ⬜/🟡 → proceed
- 🟠 → ask user
- ❌ → ask user: rollback or retry?
- (all ✅) → STOP + "feature complete, push branch + create PR"

## E5: Read current phase file

```bash
cat "$PLANS_PATH/docs/plans/<slug>/phase-NN.md"
```

Read this one phase file only — never another phase's file.

## E6: Read all "Files to read"

Parallel reads. Never read files outside the list.

## E7: Echo summary

```
✅ Resumed
   Plan:      <slug>
   Phase:     NN — <name> (<status>)
   Goal:      <1-line>
   Tasks:     <X done / Y total>
   Read budget: ~Zk tokens loaded
```

## E8: Implement Tasks

- Mark `[x]` in the phase file for each completed task → **edit `$PLANS_PATH/docs/plans/<slug>/phase-NN.md`**
- Don't implement tasks that aren't in this phase
- Don't run the next phase
- Hit a blocker → STOP + ask user

## E9: Verify Acceptance criteria

Run the test/build commands listed in the Acceptance section
- All pass → ✅
- Some fail → 🟡 + Note

## E10: Two-commit workflow (+ token cost recording)

**Step 1: Record token cost + dollar cost of this session into the overview**

Before committing the status update, capture this session's token usage + cost from JSONL.
Claude Code stores session logs at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Robust detection: glob all paths, pick the most-recently-modified (= current Sonnet session).

Per-message cost includes 5m + 1h cache + base input/output rates per model. The pricing table follows Anthropic's public pricing (per 1M tokens) — update it in this file if rates change:

| Model prefix | input | output | cache 5m write | cache 1h write | cache read |
|---|---|---|---|---|---|
| `claude-opus-4` | $15 | $75 | $18.75 | $30 | $1.50 |
| `claude-sonnet-4` / `claude-3-5-sonnet` | $3 | $15 | $3.75 | $6 | $0.30 |
| `claude-haiku-4` / `claude-3-5-haiku` | $0.80 | $4 | $1 | $1.60 | $0.08 |

```bash
read PHASE_TOKENS PHASE_COST_USD <<<"$(python3 - <<'PY'
import os, json, glob, re

PRICING = {
    # prefix → (input, output, cache_5m_write, cache_1h_write, cache_read) per MTok USD
    "claude-opus-4":     (15.00, 75.00, 18.75, 30.00, 1.50),
    "claude-sonnet-4":   ( 3.00, 15.00,  3.75,  6.00, 0.30),
    "claude-haiku-4":    ( 0.80,  4.00,  1.00,  1.60, 0.08),
    "claude-3-5-sonnet": ( 3.00, 15.00,  3.75,  6.00, 0.30),
    "claude-3-5-haiku":  ( 0.80,  4.00,  1.00,  1.60, 0.08),
    "claude-3-opus":     (15.00, 75.00, 18.75, 30.00, 1.50),
}
def rates(model):
    for p, r in PRICING.items():
        if model.startswith(p): return r
    return PRICING["claude-sonnet-4"]  # fallback

home = os.path.expanduser("~")
all_jsonls = glob.glob(f"{home}/.claude/projects/*/*.jsonl")
if not all_jsonls:
    print(0, 0); raise SystemExit
latest = max(all_jsonls, key=os.path.getmtime)

with open(latest) as f:
    lines = f.readlines()

# Find LATEST `/planner run` slash-command invocation as start marker.
# Claude Code stores user prompts with structured tags:
#   <command-name>/planner</command-name>
#   <command-args>run [<slug>]</command-args>
# Strict matching (string content + first_arg == "run") to avoid false positives
# from injected skill-body content. If marker not found → emit "?" rather than
# summing the whole file (race: marker may not be flushed to JSONL yet).
start_idx = None
for i, line in enumerate(lines):
    try:
        obj = json.loads(line)
        if obj.get("type") != "user": continue
        c = obj.get("message", {}).get("content", "")
        if not isinstance(c, str): continue
        if not re.search(r"<command-name>/?planner</command-name>", c):
            continue
        am = re.search(r"<command-args>([^<]*)</command-args>", c)
        if not am: continue
        args = am.group(1).strip()
        if not args: continue
        if args.split()[0] == "run":
            start_idx = i
    except Exception:
        pass

if start_idx is None:
    print("? ?"); raise SystemExit

# Dedupe by (message_id, usage signature) — JSONL has duplicate usage
# records per turn, causing ~1.5-2× overcounting if not deduped.
seen = set()
total_tokens = 0
total_cost = 0.0
for line in lines[start_idx:]:
    try:
        obj = json.loads(line)
        msg = obj.get("message", {})
        model = msg.get("model")
        u = msg.get("usage")
        if not (model and isinstance(u, dict)): continue
        mid = msg.get("id") or obj.get("uuid")
        key = (mid, json.dumps(u, sort_keys=True))
        if key in seen: continue
        seen.add(key)
        in_t  = u.get("input_tokens", 0)
        out_t = u.get("output_tokens", 0)
        cr_t  = u.get("cache_read_input_tokens", 0)
        cc    = u.get("cache_creation") or {}
        c5_t  = cc.get("ephemeral_5m_input_tokens", 0)
        c1_t  = cc.get("ephemeral_1h_input_tokens", 0)
        if not (c5_t or c1_t):
            c5_t = u.get("cache_creation_input_tokens", 0)
        r = rates(model)
        total_tokens += in_t + out_t + cr_t + c5_t + c1_t
        total_cost += (in_t*r[0] + out_t*r[1] + c5_t*r[2] + c1_t*r[3] + cr_t*r[4]) / 1_000_000
    except: pass
print(f"{total_tokens} {total_cost:.2f}")
PY
)"
[[ -z "$PHASE_TOKENS" || "$PHASE_TOKENS" -eq 0 ]] && PHASE_TOKENS="?"
[[ -z "$PHASE_COST_USD" || "$PHASE_COST_USD" == "0.00" ]] && PHASE_COST_USD="?"
```

**Why marker-based:** summing the entire JSONL is wrong in many cases — same session multi-phase, /clear+rerun, etc. The marker (latest `/planner run` slash-command invocation) sidesteps this: count only messages that occurred after the user started this phase.

**Step 2: Update `_overview.md` — append/update "Costs" section**

If Costs section doesn't exist yet → create it. If it does → append a new row:

```markdown
## Costs

| Phase | Tokens | USD | Model | Note |
|---|---|---|---|---|
| 01 | ~25,432 | $0.13 | sonnet | |
| 02 | ~31,108 | $0.18 | sonnet | |
```

(Token = input + output + cache read + cache creation. USD = sum of per-message cost using rates table above. Model = primary model used in that phase's session — read from JSONL `message.model`)

**Step 3: Commit 1 — code → feature branch + push to remote**

```bash
git add <code-files-touched>
git commit -m "phase-NN: <name>"   # or "wip(phase-NN): ..." for partial work

# MANDATORY: push code to remote at every phase end.
# -u sets upstream on first push; harmless on subsequent pushes.
git push -u origin "$(git branch --show-current)"
```

> **Why push every phase:** each phase is a checkpoint. Pushing means work survives a lost laptop / wiped worktree, teammates can see progress, and CI runs per phase rather than one giant batch at the end. The Stop hook enforces this — it blocks if the phase's code commit isn't pushed.

**Step 4: Commit 2 — status + costs → plans branch (`_plans` worktree)**

```bash
# Edit _overview.md → update Status column + Costs table
# Edit phase-NN.md → tick [x] for every actually-completed task

git -C "$PLANS_PATH" add "docs/plans/<slug>/"
git -C "$PLANS_PATH" commit -m "phase-NN status: <slug> (~<PHASE_TOKENS> tokens)"
git -C "$PLANS_PATH" push origin plans
```

> **Why 2 commits:** code lives on the feature branch (gets squashed + PR'd into develop), plan-status lives on the plans branch (separate history, doesn't pollute the feature PR). **Both branches are pushed at every phase end** — no local-only state survives a phase boundary.

## E11: Hand-off (+ cleanup prompt on completion)

### E11.1: Detect completion state

```bash
# Re-read overview after E10 status commit
NON_DONE=$(grep -E '^\| *[0-9]+ *\|' "$PLANS_PATH/docs/plans/$SLUG/_overview.md" | grep -v '✅' | head -1 || true)
if [[ -z "$NON_DONE" ]]; then
    PLAN_COMPLETE=1
else
    PLAN_COMPLETE=0
fi
```

### E11.2: Sum token + dollar cost before cleanup

```bash
if [[ "$PLAN_COMPLETE" -eq 1 ]]; then
    # Read Costs table from overview, sum tokens + USD across phases
    read TOTAL_TOKENS TOTAL_COST_USD <<<"$(python3 - "$PLANS_PATH/docs/plans/$SLUG/_overview.md" <<'PY'
import sys, re
toks = 0
cost = 0.0
with open(sys.argv[1]) as f:
    in_costs = False
    for line in f:
        if line.startswith("## Costs"):
            in_costs = True; continue
        if in_costs and line.startswith("## "):
            break
        if in_costs:
            # | NN | ~25,432 | $0.13 | sonnet | ... |
            m = re.match(r"^\| *\d+ *\| *~?([\d,]+) *\| *\$?([\d.]+) *\|", line)
            if m:
                toks += int(m.group(1).replace(",", ""))
                cost += float(m.group(2))
print(f"{toks} {cost:.2f}")
PY
)"
fi
```

### E11.3: Prompt before cleanup if plan complete

If plan is complete → **show the summary (including total tokens + USD) FIRST**, then ask user whether to delete or keep. **Never delete immediately** — user may want to keep the snapshot for retrospective, or marker detection could have been wrong.

```bash
if [[ "$PLAN_COMPLETE" -eq 1 ]]; then
    # 1. Print full completion summary FIRST (cost block from E11.2 + per-phase breakdown).
    #    Token formatting rule (S3-4): ≥1M → "X.XM", <1M → "Nk".
    #    See E11.4 hand-off template — print that here BEFORE the prompt.

    # 2. Then ask explicitly:
    cat <<EOF

──────────────────────────────────────────────
🗑️   CLEANUP PROMPT
──────────────────────────────────────────────

  Plan files at: docs/plans/$SLUG/  (overview + ${PHASE_COUNT} phase files)
  Total used:    ~${TOTAL_TOKENS_FMT}  ·  \$${TOTAL_COST_USD}

  Delete plan folder from plans branch tip?
  (History preserved in git log either way — recover via:
   git -C "\$PLANS_PATH" log --all -- docs/plans/$SLUG/)

  [k]eep      keep visible in _plans worktree (default)
  [d]elete    remove from tip, archive to git log

EOF

    # 3. Wait for user reply, default = keep on empty/unclear input.
    # If user replies 'd' / 'delete' / 'yes' → run cleanup commit:

    git -C "$PLANS_PATH" rm -r "docs/plans/$SLUG/"
    git -C "$PLANS_PATH" commit -m "cleanup: $SLUG complete — plan archived in git history

All phases ✅ done. Total: ~${TOTAL_TOKENS} tokens (\$${TOTAL_COST_USD}).
Plan files removed from plans branch tip.
Recover anytime via: git -C \"\$PLANS_PATH\" log --all -- docs/plans/$SLUG/
"
    git -C "$PLANS_PATH" push origin plans

    # If user replied 'k' or anything else → skip cleanup, just print:
    echo "✅  Plan kept at docs/plans/$SLUG/  (delete later via: git -C \"\$PLANS_PATH\" rm -rf docs/plans/$SLUG/)"
fi
```

> **Why ask before deleting:** plan complete ≠ artifact the user wants to throw away immediately. In many cases the user wants to keep it for retrospective, reference the decisions log when writing the PR description, or debug if the last phase commit went wrong. A 1-step prompt lets the user choose — default = keep (safer).
>
> **Why history is still recoverable after delete:** the plans branch keeps every commit from plan creation, through phase status updates, to the cleanup commit. `git log --all -- docs/plans/<slug>/` shows the full history. `git show <hash>:docs/plans/<slug>/_overview.md` views any snapshot in time.

### E11.3: Hand-off message

**If not yet complete:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✅  PHASE NN: <name>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Status         ✅ done / 🟡 partial / 🟠 blocked
  Code commit    <hash>  (feature branch)
  Status commit  <hash>  (plans branch)

──────────────────────────────────────────────
💰  COST  (this phase + cumulative)
──────────────────────────────────────────────

  This phase   ~<N>M  · $<X.XX>  (sonnet)

  Spent so far (✅ rows from overview):
    Plan     ~<N>M   · $<X.XX>  (opus)
    01..NN   ~<N>M   · $<X.XX>  (sonnet)
    ────────────────────────────
    Total    ~<N>M   · $<X.XX>

  Remaining (⬜ rows, est):
    (NN+1)..N  ~<N>M  · ~$<X.XX>

  Projected feature total:  ~$<X.XX>

  (Read overview's Costs table after writing this phase row.
   Apply token formatting rule from S3-4.)

──────────────────────────────────────────────
🎯  NEXT
──────────────────────────────────────────────

  phase-(NN+1) — <next-name>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
👉  CONTINUE — Pick one:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ┌────────────────────────────────────────┐
  │  ⭐ Option A — Same session  (default) │
  └────────────────────────────────────────┘

      /clear
      /planner run

      ✓  Faster: starts in ~2s
      ✓  Cheaper: cache reuse saves ~$0.30
      ✓  Auto-loads project context (init skill) internally

  ┌────────────────────────────────────────┐
  │  Option B — New session  (when needed) │
  └────────────────────────────────────────┘

      → close + reopen Claude Code (Sonnet 4.6)
      → /planner run

      Use when:
        • Need to switch model
        • Already ran ≥5 phases this session (JSONL bloat)
        • Suspect state corruption
        • Want different worktree

──────────────────────────────────────────────
ℹ️   /clear vs /init
──────────────────────────────────────────────

  /clear  →  Wipes conversation history       (you type)
  /init   →  Loads project knowledge          (skill auto-calls)
```

### Between phases — `/clear` vs new session?

Both work — token tracking is marker-based (it splits phases at the most recent `/planner run` line in JSONL), so:

| Method | Pros | Cons |
|---|---|---|
| **New session** (close + reopen) | Fresh JSONL, fresh model picker, works everywhere | Have to reopen Claude Code |
| **`/clear` in same session** | Faster, no reopening | ⚠️ `/clear` does **not** change model — you must switch the model yourself if needed (see caveats below) |

**Caveats for `/clear`:**
- Model stays whatever the session was on before `/clear`. If you were on Opus (planning) and ran `/clear` → still Opus. Switch to Sonnet 4.6 before `/planner run`.
- JSONL grows monotonically — performance may slow on very long sessions (~500+ phases). Practical cap: ~10 phases per session before reopening.

**Caveats for new session:**
- Must reopen Claude Code at the same worktree path
- Does not affect token tracking or correctness

Recommendation: **`/clear` if the phase uses the same model**, **new session if switching model**.

---

**If complete:** (Print FIRST, then E11.3 cleanup prompt)
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎉  FEATURE COMPLETE — <slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  All phases  ✅  N/N
  Last code commit    <hash>  (<PLAN_BRANCH>)

──────────────────────────────────────────────
💰  COST BREAKDOWN
──────────────────────────────────────────────

  Plan        ~9.2M    ·  $24.63   (opus)
  Phase 01    ~6.8M    ·  $3.43    (sonnet)
  Phase 02    ~7.2M    ·  $3.61    (sonnet)
  Phase 03    ~5.1M    ·  $2.55    (sonnet)
                ───────    ─────
  Total       ~<TOTAL_TOKENS>  ·  $<TOTAL_COST_USD>

  Estimate was $<EST> → actual $<TOTAL>  (<+/-N%>)

  (Token format: ≥1M → "X.XM", <1M → "Nk")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀  NEXT STEPS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1.  Push feature branch:
      git push -u origin <PLAN_BRANCH>

  2.  Create PR:
      gh pr create --base <base-branch> \
        --title "feat: <feature>" \
        --body "Implements docs/plans/<slug> (archived)"

──────────────────────────────────────────────
📚  PLAN HISTORY
──────────────────────────────────────────────

  (After E11.3 prompt — show ONE based on user choice:)

  ▸ If [d]elete:
      Plan files removed from plans branch tip (cleanup commit <hash>).
      Recover anytime: git -C "$PLANS_PATH" log --all -- docs/plans/<slug>/

  ▸ If [k]eep (default):
      Plan files preserved at docs/plans/<slug>/
      Delete later: git -C "$PLANS_PATH" rm -rf docs/plans/<slug>/
```

> **USD computed as:** `(input × in_rate + output × out_rate + cache_5m × c5m_rate + cache_1h × c1h_rate + cache_read × cr_rate) / 1M`. Rates by model prefix (Opus 4.x: input $15, output $75; Sonnet 4.x: $3/$15; Haiku 4.x: $0.80/$4 per MTok). Approximation within ~5% (may drift if Anthropic changes pricing — update the PRICING dict in E10 step 1).

### E11.4: Stash recovery hint

```bash
STASHES=$(git stash list 2>/dev/null | grep "auto-stash before /planner run" || true)
if [[ -n "$STASHES" ]]; then
  echo ""
  echo "📦 Auto-stash pending — work from before this phase started:"
  echo "$STASHES"
  echo ""
  echo "Recovery (when ready; may conflict if this phase touched the same files):"
  echo "   git checkout <original-branch>"
  echo "   git stash pop"
fi
```

---

# Status Mode (`/planner status`)

**Read-only.** No edits, no commits.

## S1: Pre-check

```bash
[[ -e "$PLANS_PATH/.git" ]] || { echo "STOP: run /planner setup first"; exit; }
git -C "$PLANS_PATH" pull --ff-only origin plans 2>&1
```

## S2: Discover plans

```bash
find "$PLANS_PATH/docs/plans" -mindepth 1 -maxdepth 1 -type d | sort
```

| Result | Action |
|---|---|
| 0 | "No plan yet — run `/planner <feature>`" → STOP |
| 1 | use it |
| ≥ 2 & user passed slug | use the slug |
| ≥ 2, no slug | list 1-line summary of each → STOP + ask user to specify |

## S3-4: Read + format output

**Token formatting rule (apply everywhere tokens are shown):**
- `< 1,000` → `<N>` (no suffix)
- `1,000 – 999,999` → `<N>k` (round to nearest 1k, e.g. `780k`, `12k`)
- `≥ 1,000,000` → `<N.N>M` (1 decimal, e.g. `1.2M`, `7.0M`, `11.7M`)
- Strip trailing `.0` (`7.0M` → `7M` is OK if exact)

Examples:
- `7,000,481` → `~7.0M`
- `11,698,234` → `~11.7M`
- `780,453` → `~780k`
- `21,200,150` → `~21.2M`

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋  PLAN: <Feature Name>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Slug          <slug>
  Code branch   <recorded>  (current: <actual>  ✅ match / ℹ️ different)
  Plans branch  plans @ <hash>
  Created       <date>

──────────────────────────────────────────────
📊  PROGRESS
──────────────────────────────────────────────

  X of N phases done

  ▓▓▓░░░░░░░  <%>%

──────────────────────────────────────────────
🗂️   PHASES
──────────────────────────────────────────────

  ✅  01  <name>     <commit hash>
  🟡  02  <name>     in-progress · X/Y tasks
  ⬜  03  <name>     pending

──────────────────────────────────────────────
🎯  CURRENT: phase NN — <name>
──────────────────────────────────────────────

  Goal:
    <1-2 line goal from phase file>

──────────────────────────────────────────────
📌  DECISIONS  (top 3)
──────────────────────────────────────────────

  D1  <decision>     → phase X
  D2  <decision>     → phase Y
  D3  <decision>     → phase Z

──────────────────────────────────────────────
🚧  BLOCKERS  (skip if none)
──────────────────────────────────────────────

  Phase NN — <note>

──────────────────────────────────────────────
💰  COSTS  (actual / estimate)
──────────────────────────────────────────────

  ✅ Done so far:
    Plan   ~<N>M   · $<X.XX>  (opus)
    01     ~<N>M   · $<X.XX>  (sonnet)

  ⏳ Remaining (estimate from overview):
    02     ~<N>k   · ~$<X.XX>  (sonnet)
    03     ~<N>k   · ~$<X.XX>  (sonnet)
    04     ~<N>k   · ~$<X.XX>  (sonnet)
    05     ~<N>k   · ~$<X.XX>  (sonnet)

  ──────────────────────────────────────
  Spent so far:    ~<N>M  · $<X.XX>
  Est remaining:   ~<N>M  · ~$<X.XX>
  Projected total: ~<N>M  · ~$<X.XX>

  (Read estimates from overview's Costs table "(est)" rows.
   Apply token formatting rule from top of S3-4.)

──────────────────────────────────────────────
📜  RECENT COMMITS  (plans branch)
──────────────────────────────────────────────

  <hash>  phase-NN status: <slug> (~<N>M tokens)
  <hash>  plan: <feature>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
▶  NEXT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Option A (recommended):
    /clear
    /planner run
```

---

# List Mode (`/planner list`)

**Read-only.** Show all plans (active + archived) at a glance.

## L1: Pre-check

```bash
[[ -e "$PLANS_PATH/.git" ]] || { echo "STOP: run /planner setup first"; exit; }
git -C "$PLANS_PATH" pull --ff-only origin plans 2>&1
```

## L2: Discover all plans (current + archived)

```bash
# Active plans = folders that exist on plans branch tip
ACTIVE_PLANS=$(find "$PLANS_PATH/docs/plans" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

# Archived plans = slugs that appeared in cleanup/abort commits but no longer exist
ARCHIVED=$(git -C "$PLANS_PATH" log --all --pretty=format:"%H %s" \
  | grep -E "^[a-f0-9]+ (cleanup|abort): " \
  | awk '{print $3}' | sort -u)
```

## L3: For each plan, classify state

For each active plan:
- Read `_overview.md` Status table
- Count phases done (✅), in-progress (🟡), blocked (🟠), pending (⬜)
- Read Costs table → sum actual USD spent
- State: `active` | `complete` (all ✅) | `aborted` (status header has ❌)

For each archived plan (in git log only):
- Read commit subject — extract type: `cleanup` (completed) | `abort` (cancelled)
- `git -C "$PLANS_PATH" show <hash>:<path>/_overview.md` to recover totals if needed

## L4: Format output

Apply token formatting rule (S3-4): `≥1M → X.XM`, `<1M → Nk`.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋  PLANS — All
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

──────────────────────────────────────────────
🟢  ACTIVE  (N)
──────────────────────────────────────────────

  mention-in-group       2/5 done   $7.04 spent + $24.63 plan = $31.67
  inbox-sync             0/3 done   just planned · $11.13 plan
  refactor-storage       1/4 done   🟠 phase 02 blocked  · $4.20 spent

──────────────────────────────────────────────
✅  COMPLETE  (N) — files still on tip
──────────────────────────────────────────────

  notification-fix       3/3 ✅     $14.20 total

──────────────────────────────────────────────
📚  ARCHIVED  (N) — recover via git log
──────────────────────────────────────────────

  cleanup:
    settings-redesign    completed 2026-04-15  $52.30 total
    user-search          completed 2026-03-22  $28.10 total

  aborted:
    legacy-migration     aborted 2026-04-02   "scope changed, doing differently"

──────────────────────────────────────────────
💡  TIPS
──────────────────────────────────────────────

  /planner status <slug>     drill into one plan
  /planner cleanup <slug>    archive completed plan
  /planner abort <slug>      mark plan abandoned
```

If no active plans → STOP, suggest `/planner <feature>` to create one.

---

# Cleanup Mode (`/planner cleanup <slug>`)

**Action: delete plan files from plans branch tip, preserving git history.** Used when user replied `[k]eep` after FEATURE COMPLETE prompt and now wants to archive.

## CL1: Pre-check

```bash
SLUG="$1"
[[ -z "$SLUG" ]] && { echo "STOP: usage: /planner cleanup <slug>"; exit; }
[[ -e "$PLANS_PATH/.git" ]] || { echo "STOP: run /planner setup first"; exit; }
[[ -d "$PLANS_PATH/docs/plans/$SLUG" ]] || { echo "STOP: plan '$SLUG' not found on tip"; exit; }
git -C "$PLANS_PATH" pull --ff-only origin plans 2>&1
```

## CL2: Confirm completeness (or warn)

```bash
NON_DONE=$(grep -E '^\| *[0-9]+ *\|' "$PLANS_PATH/docs/plans/$SLUG/_overview.md" | grep -v '✅' | head -1 || true)

if [[ -n "$NON_DONE" ]]; then
    echo "⚠️   Plan '$SLUG' has incomplete phases:"
    grep -E '^\| *[0-9]+ *\|' "$PLANS_PATH/docs/plans/$SLUG/_overview.md" | grep -v '✅' || true
    echo ""
    echo "   Cleanup deletes files but git history stays."
    echo "   For incomplete plans, prefer: /planner abort $SLUG"
    echo ""
    echo "   Continue cleanup anyway? [y/N]"
    # Wait for user reply
fi
```

## CL3: Sum cost from overview before deleting

(same as E11.2 — read Costs table, sum actual USD)

## CL4: Delete + commit + push

```bash
git -C "$PLANS_PATH" rm -r "docs/plans/$SLUG/"
git -C "$PLANS_PATH" commit -m "cleanup: $SLUG complete — plan archived in git history

Total: ~${TOTAL_TOKENS_FMT} tokens (\$${TOTAL_COST_USD}).
Plan files removed from plans branch tip.
Recover anytime via: git -C \"\$PLANS_PATH\" log --all -- docs/plans/$SLUG/
"
git -C "$PLANS_PATH" push origin plans
```

## CL5: Confirm

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🗑️   PLAN ARCHIVED — <slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Files removed:    docs/plans/<slug>/
  Cleanup commit:   <hash>  (plans branch)
  Total cost:       ~<TOTAL_TOKENS>  ·  $<TOTAL_COST_USD>

  Recover anytime:
    git -C "$PLANS_PATH" log --all -- docs/plans/<slug>/
    git -C "$PLANS_PATH" show <hash>:docs/plans/<slug>/_overview.md
```

---

# Abort Mode (`/planner abort <slug> [<reason>]`)

**Action: mark plan as ❌ aborted, keep files visible (don't delete).** Used when work is no longer needed (scope changed, decided not to proceed, replaced by different approach).

## AB1: Pre-check

```bash
SLUG="$1"; shift
REASON="$*"
[[ -z "$SLUG" ]] && { echo "STOP: usage: /planner abort <slug> [<reason>]"; exit; }
[[ -d "$PLANS_PATH/docs/plans/$SLUG" ]] || { echo "STOP: plan '$SLUG' not found"; exit; }

# Default reason if empty
if [[ -z "$REASON" ]]; then
    REASON="aborted by user (no reason given)"
fi
```

## AB2: Update overview header + status table

Add `**Status:** ❌ ABORTED — <reason>` line near the top, replace any `🟡` / `⬜` rows with `❌` to make it visible at a glance.

```bash
python3 - "$PLANS_PATH/docs/plans/$SLUG/_overview.md" "$REASON" <<'PY'
import sys, re
path = sys.argv[1]
reason = sys.argv[2]
with open(path) as f:
    text = f.read()
# Insert abort banner after first H1
text = re.sub(r'(^# [^\n]+\n)', r'\1\n**Status:** ❌ ABORTED — ' + reason + '\n', text, count=1)
# Mark non-done phases as ❌ aborted
text = re.sub(r'\| *(⬜ pending|🟡 in-progress|🟠 blocked) *\|', '| ❌ aborted |', text)
with open(path, 'w') as f:
    f.write(text)
PY
```

## AB3: Commit (don't push delete — keep files)

```bash
git -C "$PLANS_PATH" add "docs/plans/$SLUG/_overview.md"
git -C "$PLANS_PATH" commit -m "abort: $SLUG — $REASON

Plan files preserved on tip for reference.
Run /planner cleanup $SLUG to remove from tip if desired.
"
git -C "$PLANS_PATH" push origin plans
```

## AB4: Confirm

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌  PLAN ABORTED — <slug>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Reason:           <reason>
  Abort commit:     <hash>  (plans branch)
  Files preserved:  docs/plans/<slug>/  (overview marked ❌)

  Cost so far:      ~<TOTAL_TOKENS>  ·  $<TOTAL_COST_USD>

  Next options:
    Delete files:   /planner cleanup <slug>
    Resume later:   manually edit overview to remove ❌ banner
```

---

# Help Mode (`/planner help`)

**Read-only.** Print mode reference + key paths. No git ops.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🗒️   PLANNER — Mode Reference
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Lifecycle:
    /planner setup                    One-time bootstrap (per machine)
    /planner <feature description>    Plan a new feature   (Opus 4.7)
    /planner run [<slug>]             Execute next phase   (Sonnet 4.6)
    /planner status [<slug>]          Read-only progress

  Manage plans:
    /planner list                     List all plans (active + archived)
    /planner cleanup <slug>           Archive completed plan
    /planner abort <slug> [<reason>]  Mark plan abandoned (keep files)

  Help:
    /planner help                     This message

──────────────────────────────────────────────
📂  KEY PATHS
──────────────────────────────────────────────

  .claude/commands/planner.md             This skill
  .claude/commands/planner-init.md        Project context loader (auto-installed)
  .claude/hooks/planner-remind-phase.sh   PreToolUse hook
  .claude/hooks/planner-stop-check.sh     Stop hook
  .claude/worktrees/_plans/               Plans worktree (orphan branch)
  .claude/worktrees/_plans/docs/plans/    Active plan folders

──────────────────────────────────────────────
🎬  TYPICAL FLOW
──────────────────────────────────────────────

  Once per machine:
    1. /planner setup

  Per feature:
    2. /planner add my new feature      (Opus plans)
    3. /clear + switch to Sonnet
    4. /planner run                     (Phase 01)
    5. /clear, /planner run             (Phase 02 ... N)
    6. Last phase → cleanup prompt → [k]eep or [d]elete

──────────────────────────────────────────────
📚  DOCS
──────────────────────────────────────────────

  https://github.com/Thanaphon041/planner-skill
```

---

## Rules (immutable, all modes)

1. **Don't run planner in the main repo** — always use a feature worktree
2. **Don't hallucinate paths** — verify every file exists before writing it into the plan
3. **Don't read other phase files** during execution — phases are self-contained
4. **Don't skip Acceptance** — actually run `<test-cmd>` (npm test / pytest / cargo test / etc.)
5. **2-commit workflow in E10 must be completed** — forgetting to push plans branch = team can't see it
6. **Decisions Log lives in `_overview.md` only** — phase files must NOT add new decisions (exception: auto-generated `D-retarget-NN` entries from E3 silent retarget)
7. **`plans` branch must NOT merge into develop** — it's an orphan branch, parallel timeline
8. **Don't ask "are you on the right branch?" or "A/B which worktree?"** — P1 auto-rebrands, E3 silent retargets. User invoked the command from a specific worktree on purpose; respect that instead of forcing a re-confirmation.
9. **Code branch must be a real `<type>/<slug>` ref** — never auto-named `claude/<random>`. P1 creates one if needed.

---

## Anti-patterns

- ❌ Cramming the entire feature into 1 phase
- ❌ A phase with only 1 task
- ❌ Acceptance "code works"
- ❌ Leaving TBD / placeholder behind
- ❌ Planning + implementing in the same session
- ❌ Forgetting to push the plans branch after E10
- ❌ Editing `_plans` worktree's `.git` or working tree manually (use `git -C` instead)
- ❌ Use auto-named `claude/<random>` as `Code branch:` — P1 must rebrand to `<type>/<slug>` first
- ❌ Asking user "continue on branch X or Y?" on E3 mismatch — silent retarget always
