#!/usr/bin/env bash
# Stop hook: enforce 2-commit + push workflow for /planner run
# Block stopping when:
#   1. _plans worktree is set up
#   2. Current phase has all Tasks ticked [x]
#   3. Code uncommitted in feature worktree (or last commit doesn't reference phase)
#      OR code committed but NOT pushed to remote
#      OR _overview.md uncommitted in plans worktree
# Otherwise: allow stop.

set -euo pipefail

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Resolve plans worktree
MAIN_REPO=$(git -C "$PROJECT_ROOT" worktree list 2>/dev/null | head -1 | awk '{print $1}')
[[ -z "$MAIN_REPO" ]] && exit 0

PLANS_PATH="$MAIN_REPO/.claude/worktrees/_plans"
# .git is a file in worktrees, not a dir
[[ ! -e "$PLANS_PATH/.git" ]] && exit 0  # not setup yet

PLANS_DIR="$PLANS_PATH/docs/plans"
[[ ! -d "$PLANS_DIR" ]] && exit 0

# Find active plan (most recently modified _overview.md)
PLAN_DIR=""
for d in "$PLANS_DIR"/*/; do
  [[ -f "${d}_overview.md" ]] || continue
  PLAN_DIR="${d%/}"
  break
done
[[ -z "$PLAN_DIR" ]] && exit 0

OVERVIEW="$PLAN_DIR/_overview.md"
SLUG=$(basename "$PLAN_DIR")

# Find current phase (first non-✅ row)
CURRENT=$(grep -E '^\| *[0-9]+ *\|' "$OVERVIEW" 2>/dev/null \
  | grep -v '✅' | head -1 \
  | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' || true)
[[ -z "$CURRENT" ]] && exit 0  # all phases ✅ done

PHASE_FILE="$PLAN_DIR/phase-${CURRENT}.md"
[[ ! -f "$PHASE_FILE" ]] && exit 0

# Trigger: all tasks ticked, zero unticked?
UNCHECKED=$(grep -cE '^- \[ \]' "$PHASE_FILE" || true)
CHECKED=$(grep -cE '^- \[x\]' "$PHASE_FILE" || true)
if [[ "$UNCHECKED" -ne 0 || "$CHECKED" -eq 0 ]]; then
  exit 0  # not finished, allow stop
fi

# Code state in feature worktree (current cwd)
cd "$PROJECT_ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
CODE_CHANGES=$(git status --porcelain 2>/dev/null | head -1 || true)
LAST_CODE_COMMIT_MSG=$(git log -1 --format=%s 2>/dev/null || true)
CODE_BRANCH=$(git branch --show-current 2>/dev/null || true)

# Is the feature branch pushed? (committed is not enough — phase = checkpoint)
# No upstream     → never pushed         → not pushed
# upstream + ahead → committed not pushed → not pushed
# upstream + even  → pushed               → ok
CODE_PUSHED=false
if CODE_UPSTREAM=$(git rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
  CODE_UNPUSHED=$(git log '@{u}..HEAD' --oneline 2>/dev/null | head -1 || true)
  [[ -z "$CODE_UNPUSHED" ]] && CODE_PUSHED=true
fi

# Plans state in _plans worktree
PLANS_CHANGES=$(git -C "$PLANS_PATH" status --porcelain 2>/dev/null | head -1 || true)
LAST_PLANS_COMMIT_MSG=$(git -C "$PLANS_PATH" log -1 --format=%s 2>/dev/null || true)

# Heuristic: did this session commit phase-NN to either branch?
PHASE_REF="phase-${CURRENT}"

CODE_COMMITTED=false
if [[ -z "$CODE_CHANGES" ]] && [[ "$LAST_CODE_COMMIT_MSG" == *"$PHASE_REF"* ]]; then
  CODE_COMMITTED=true
fi

# CODE_OK requires BOTH committed AND pushed
CODE_OK=false
if $CODE_COMMITTED && $CODE_PUSHED; then
  CODE_OK=true
fi

PLANS_OK=false
if [[ -z "$PLANS_CHANGES" ]] && [[ "$LAST_PLANS_COMMIT_MSG" == *"$PHASE_REF"* || "$LAST_PLANS_COMMIT_MSG" == *"$SLUG"* ]]; then
  PLANS_OK=true
fi

if $CODE_OK && $PLANS_OK; then
  exit 0  # both committed + pushed, all good
fi

# Code status detail string
if $CODE_COMMITTED && $CODE_PUSHED; then
  CODE_STATUS='✅ committed + pushed'
elif $CODE_COMMITTED; then
  CODE_STATUS="⚠️ committed but NOT pushed — run: git push -u origin $CODE_BRANCH"
else
  CODE_STATUS="⚠️ uncommitted changes OR last commit doesn't reference $PHASE_REF"
fi

# Build reason
REASON="Phase $CURRENT of $SLUG appears complete (all Tasks ticked) but the 2-commit + push workflow is not finished:

- Feature branch (code): $CODE_STATUS
- Plans branch (status): $([ "$PLANS_OK" = true ] && echo '✅ committed + pushed' || echo "⚠️ _overview.md not updated/committed in $PLANS_PATH")

Before stopping, run:
  # 1. Code commit + push (in current worktree)
  git add <code-files>
  git commit -m \"phase-$CURRENT: <name>\"
  git push -u origin $CODE_BRANCH

  # 2. Status update + push (in plans worktree)
  # Edit $OVERVIEW Status column → ✅/🟡/🟠
  git -C \"$PLANS_PATH\" add docs/plans/$SLUG/
  git -C \"$PLANS_PATH\" commit -m \"phase-$CURRENT status: $SLUG\"
  git -C \"$PLANS_PATH\" push origin plans

If changes are unrelated to phase $CURRENT, mention so explicitly."

python3 - "$REASON" <<'PY'
import json, sys
print(json.dumps({"decision": "block", "reason": sys.argv[1]}))
PY

exit 0
