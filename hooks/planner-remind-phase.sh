#!/usr/bin/env bash
# PreToolUse hook for Edit|Write|MultiEdit
# Re-injects current phase context to combat "lost in middle" effect
# Reads from _plans worktree (dedicated `plans` branch design)
# No-op silently if no setup OR if writing meta files (plan/skill/hook)

set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Resolve main repo + plans worktree
MAIN_REPO=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | head -1 | awk '{print $1}')
[[ -z "$MAIN_REPO" ]] && exit 0

PLANS_PATH="$MAIN_REPO/.claude/worktrees/_plans"
PLANS_DIR="$PLANS_PATH/docs/plans"

# Setup not done → silent
# (.git is a file in worktrees, not a dir — use -e instead of -d)
[[ ! -e "$PLANS_PATH/.git" ]] && exit 0
[[ ! -d "$PLANS_DIR" ]] && exit 0

# Skip meta-file writes (planner-mode authoring)
TARGET_FILE=$(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("tool_input", {}).get("file_path", ""))
except Exception:
    print("")
' 2>/dev/null || echo "")

if [[ -n "$TARGET_FILE" ]]; then
  case "$TARGET_FILE" in
    */_plans/*|*/.claude/commands/*|*/.claude/hooks/*|*/.claude/settings*)
      exit 0  # planner-mode write, no reminder needed
      ;;
  esac
  # Skip if target file is OUTSIDE the active project root.
  # Editing a file in another project = unrelated to any plan here.
  case "$TARGET_FILE" in
    "$PROJECT_ROOT"/*) ;;  # inside project — proceed
    *)
      exit 0  # outside project — skip reminder
      ;;
  esac
fi

# Match plan to current branch, NOT just "first plan we find".
# Without this filter, hook fires whenever any plan exists in _plans/ —
# including when user is doing unrelated work on a different branch.
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || true)
[[ -z "$CURRENT_BRANCH" ]] && exit 0  # detached HEAD or not a repo

# Find the plan whose recorded "Code branch:" matches user's current branch.
# Plan folders may have format `**Code branch:** `feat/x`` (backticks) or
# `**Code branch:** feat/x` (plain) — strip both.
PLAN_DIR=""
for d in "$PLANS_DIR"/*/; do
  [[ -f "${d}_overview.md" ]] || continue
  PLAN_BRANCH=$(grep -E '^\*\*Code branch:\*\*' "${d}_overview.md" 2>/dev/null \
    | head -1 \
    | sed -E 's/^\*\*Code branch:\*\*[[:space:]]*//; s/^`//; s/`.*$//; s/[[:space:]]+$//' \
    || true)
  if [[ "$PLAN_BRANCH" == "$CURRENT_BRANCH" ]]; then
    PLAN_DIR="${d%/}"
    break
  fi
done

# No plan matches current branch → user is doing unrelated work. Stay silent.
[[ -z "$PLAN_DIR" ]] && exit 0

OVERVIEW="$PLAN_DIR/_overview.md"
SLUG=$(basename "$PLAN_DIR")

# Find current phase: first row in Status table without ✅
CURRENT=$(grep -E '^\| *[0-9]+ *\|' "$OVERVIEW" 2>/dev/null \
  | grep -v '✅' \
  | head -1 \
  | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' || true)

[[ -z "$CURRENT" ]] && exit 0  # all phases done

PHASE_FILE="$PLAN_DIR/phase-${CURRENT}.md"
[[ ! -f "$PHASE_FILE" ]] && exit 0

# Pull just the Goal section
GOAL=$(awk '
  /^## Goal/ { capture=1; next }
  /^## / && capture { capture=0 }
  capture { print }
' "$PHASE_FILE" | sed '/^[[:space:]]*$/d' | head -8 || true)

MSG="[planner active · plans branch] feature=$SLUG · current phase=$CURRENT · file=$PHASE_FILE

Goal of current phase:
$GOAL

Reminder: Stay within this phase's 'Files to create / modify' list. If editing outside scope, stop and ask the user before proceeding. Mark Acceptance criteria as you go. Remember the 2-commit workflow: code → feature branch, status → plans branch (via git -C \"$PLANS_PATH\")."

python3 - "$MSG" <<'PY'
import json, sys
msg = sys.argv[1]
print(json.dumps({
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": msg
  }
}))
PY

exit 0
