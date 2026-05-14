# Add this section to your project's CLAUDE.md

Place under your existing project rules, customize placeholders.

---

## Planning Large Tasks (Opus → Sonnet handoff)

For features that won't fit in one session (multi-module touch, refactors, migrations):

**TL;DR workflow:**
- One-time per machine: `/planner setup` → bootstraps orphan `plans` branch + mounts `_plans` worktree at `<main>/.claude/worktrees/_plans/`
- Plan once (Opus): `/planner <feature>` → writes to `_plans` worktree, commits to `plans` branch (NOT to feature branch)
- Execute each phase (Sonnet): `/init` then `/planner run` → reads from `_plans`, 2 commits per phase (code → feature branch, status → plans branch)
- Status check (any model): `/planner status` → progress summary, read-only
- Repeat: phase done → close session → new session → `/init` + `/planner run` again

**Why dedicated `plans` branch:**
- Plan files persist across worktrees + machines (push `plans` branch → team sync)
- Feature branches stay 100% code → clean squash/rebase, clean PR diffs
- No "plan got merged into <base-branch>" pollution
- Auto-named worktrees (`claude/<random>`) work fine — `/planner run` finds plan via `_plans` worktree, not via current branch

**Detailed rules:**
1. **First time on a machine** — run `/planner setup` to mount the `_plans` worktree. Without this, `/planner run` will STOP and tell you to setup
2. **Use `/planner run`** — auto-detects active plan in `_plans` worktree, finds current phase, loads only that phase's file + Files-to-read
3. **Before session ends** — `/planner run` guides Status update in `_overview.md`:
   - All tasks done + acceptance pass → ✅
   - Blocked → 🟠 + 1-line Note
   - Partial → 🟡 + check off only completed tasks (don't uncheck done ones)
4. **2 commits per phase**:
   - **Code** → feature branch (current worktree): `git commit -m "phase-NN: <name>"`
   - **Status** → plans branch (`_plans` worktree): `git -C "$MAIN/.claude/worktrees/_plans" commit -m "phase-NN status: <slug>"`
   - Push plans branch after each phase: `git -C "..." push origin plans`
5. **One phase per session** — fresh Sonnet 4.6 per phase to keep context clean (or `/clear` in same session)
6. **No plan yet?** — non-trivial task (>1 phase)? Run `/planner` (Opus 4.7) first
7. **`plans` branch must NOT merge into `<base-branch>`** — orphan branch, parallel timeline. Never `git merge plans` from `<base-branch>` side
