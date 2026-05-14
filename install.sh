#!/usr/bin/env bash
# Planner Skill — non-plugin installer (works locally or via curl-bash)
#
# PREFERRED install is the Claude Code plugin:
#   claude plugin marketplace add Thanaphon041/planner-skill
#   claude plugin install planner@planner-skill
#
# This script is the fallback for projects that can't use plugins, or to
# vendor the skill directly into .claude/. It copies commands/ + hooks/
# into the target project's .claude/ directory.
#
# Local mode (after `git clone`):
#   bash install.sh /path/to/project
#
# Remote mode (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/Thanaphon041/planner-skill/main/install.sh \
#     | bash -s -- /path/to/project
#
# Non-interactive (set via env vars to skip prompts):
#   PLANNER_INIT_SKILL=init \
#   PLANNER_TEST_CMD="npm test" \
#   bash install.sh /path/to/project
#
# Note: base branch is asked by /planner setup (not install.sh) and persisted
# in the plans branch so it travels with the project.

set -euo pipefail

# ─────────────────────────────────────────────────────────
# CONFIG — fork this repo? Change these:
# ─────────────────────────────────────────────────────────
REPO_OWNER="${PLANNER_REPO_OWNER:-Thanaphon041}"
REPO_NAME="${PLANNER_REPO_NAME:-planner-skill}"
REPO_BRANCH="${PLANNER_REPO_BRANCH:-main}"
TARBALL_URL="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$REPO_BRANCH.tar.gz"

# ─────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  cat <<EOF
Usage: $0 <target-project-path>

Examples:
  Local:   bash install.sh ~/projects/my-app
  Remote:  curl -fsSL <install-url> | bash -s -- ~/projects/my-app

Env vars (skip prompts when set):
  PLANNER_INIT_SKILL       e.g. init                     (default: empty)
  PLANNER_TEST_CMD         e.g. "npm test"               (default: "gradle test")
  (base branch is asked by /planner setup, not here)
EOF
  exit 1
fi

TARGET="$1"

if [[ ! -d "$TARGET" ]]; then
  echo "❌ Target directory does not exist: $TARGET"
  exit 1
fi

if [[ ! -e "$TARGET/.git" ]]; then
  echo "❌ Target is not a git repository: $TARGET"
  exit 1
fi

# ─────────────────────────────────────────────────────────
# Source detection — local clone or remote tarball
# ─────────────────────────────────────────────────────────
SCRIPT_DIR=""
if [[ "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

SOURCE_DIR=""
CLEANUP_TMPDIR=""

if [[ -n "$SCRIPT_DIR" ]] && [[ -f "$SCRIPT_DIR/commands/planner.md" ]]; then
  # Local clone — use files next to script
  SOURCE_DIR="$SCRIPT_DIR"
  MODE="local"
else
  # Remote — download tarball
  if ! command -v curl >/dev/null; then
    echo "❌ curl required for remote install. Install curl or clone the repo manually."
    exit 1
  fi
  if ! command -v tar >/dev/null; then
    echo "❌ tar required. Install tar or clone the repo manually."
    exit 1
  fi
  TMPDIR=$(mktemp -d)
  CLEANUP_TMPDIR="$TMPDIR"
  trap 'rm -rf "$CLEANUP_TMPDIR"' EXIT

  # Try public curl first; fall back to gh CLI for private repos
  echo "📥  Fetching skill..."
  if curl -fsSL "$TARBALL_URL" 2>/dev/null | tar -xz -C "$TMPDIR" 2>/dev/null && [[ -n "$(ls -A "$TMPDIR")" ]]; then
    : # public download succeeded
  elif command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    echo "    (public download failed; trying via gh CLI for private repo...)"
    gh api "/repos/$REPO_OWNER/$REPO_NAME/tarball/$REPO_BRANCH" \
      | tar -xz -C "$TMPDIR" || {
        echo "❌ gh api download failed. Try: gh repo clone $REPO_OWNER/$REPO_NAME /tmp/skill && bash /tmp/skill/install.sh $TARGET"
        exit 1
      }
  else
    echo "❌ Failed to download. If repo is private, install gh CLI:"
    echo "      brew install gh && gh auth login"
    echo "   Or clone manually:"
    echo "      gh repo clone $REPO_OWNER/$REPO_NAME /tmp/skill && bash /tmp/skill/install.sh $TARGET"
    exit 1
  fi
  # Tarball extracts to <repo>-<branch>/
  SOURCE_DIR=$(find "$TMPDIR" -maxdepth 1 -type d ! -path "$TMPDIR" | head -1)
  if [[ -z "$SOURCE_DIR" ]] || [[ ! -f "$SOURCE_DIR/commands/planner.md" ]]; then
    echo "❌ Tarball did not contain expected files. Check $TARBALL_URL"
    exit 1
  fi
  MODE="remote"
fi

# ─────────────────────────────────────────────────────────
# Interactive vs env-var mode
# ─────────────────────────────────────────────────────────
INTERACTIVE=0
if [[ -t 0 ]]; then
  INTERACTIVE=1
elif [[ -r /dev/tty ]] && exec </dev/tty 2>/dev/null; then
  # stdin is piped (curl|bash) but tty IS accessible → ask there
  INTERACTIVE=1
fi
# If both checks fail (CI/sandbox/explicit </dev/null), fall through to
# non-interactive mode using env vars + defaults — don't error out.

# Defaults (overridable via env vars)
INIT_SKILL="${PLANNER_INIT_SKILL:-}"
TEST_CMD="${PLANNER_TEST_CMD:-gradle test}"

# Note: base branch is no longer asked at install time. /planner setup will
# ask the user interactively and persist the answer in
# .claude/worktrees/_plans/.planner-config.sh on the plans branch (so it
# travels with the project, not the install).

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦  Claude Planner Skill — Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Source: $MODE ($SOURCE_DIR)"
echo "  Target: $TARGET"
echo ""

if [[ "$INTERACTIVE" -eq 1 ]]; then
  read -rp "Init skill name (empty = install fallback 'planner-init') [$INIT_SKILL]: " input
  INIT_SKILL="${input:-$INIT_SKILL}"

  read -rp "Build/test command [$TEST_CMD]: " input
  TEST_CMD="${input:-$TEST_CMD}"

  echo ""
  echo "──────────────────────────────────────────────"
  echo "Will install with:"
  echo "  Init skill:   ${INIT_SKILL:-<none>}"
  echo "  Test command: $TEST_CMD"
  echo "  (base branch will be asked by /planner setup)"
  echo "──────────────────────────────────────────────"
  echo ""

  read -rp "Proceed? [y/N]: " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
else
  echo "Non-interactive mode (using env vars / defaults):"
  echo "  Init skill:   ${INIT_SKILL:-<none>}"
  echo "  Test command: $TEST_CMD"
fi

# ─────────────────────────────────────────────────────────
# Step 1: Copy files
# ─────────────────────────────────────────────────────────
echo ""
echo "📂  Copying files..."
mkdir -p "$TARGET/.claude/commands" "$TARGET/.claude/hooks"

# Back up any existing planner files before overwrite — protects user
# customizations on re-install / upgrade.
BACKUP_TS=$(date +%s)
BACKED_UP=0
for f in \
  "$TARGET/.claude/commands/planner.md" \
  "$TARGET/.claude/commands/planner-init.md" \
  "$TARGET/.claude/hooks/planner-remind-phase.sh" \
  "$TARGET/.claude/hooks/planner-stop-check.sh" ; do
  if [[ -f "$f" ]]; then
    cp "$f" "$f.bak.$BACKUP_TS"
    BACKED_UP=1
  fi
done
if [[ "$BACKED_UP" -eq 1 ]]; then
  echo "  ℹ️  Backed up existing planner files → *.bak.$BACKUP_TS"
fi

cp "$SOURCE_DIR/commands/planner.md"           "$TARGET/.claude/commands/"
cp "$SOURCE_DIR/hooks/planner-remind-phase.sh"          "$TARGET/.claude/hooks/"
cp "$SOURCE_DIR/hooks/planner-stop-check.sh"            "$TARGET/.claude/hooks/"
chmod +x "$TARGET/.claude/hooks/"*.sh
echo "  ✅ Copied skill + hooks"

# ─────────────────────────────────────────────────────────
# Step 2: Apply customizations
# ─────────────────────────────────────────────────────────
echo ""
echo "🔧  Customizing placeholders..."
SKILL_FILE="$TARGET/.claude/commands/planner.md"

# Note: <base-branch> placeholders in planner.md are NOT substituted here.
# /planner setup writes runtime config to the plans branch which is sourced
# by every mode (see Path resolution section in planner.md).
sed -i.bak "s|<test-cmd>|$TEST_CMD|g"        "$SKILL_FILE"
sed -i.bak "s|<build-cmd>|$TEST_CMD|g"       "$SKILL_FILE"

if [[ -n "$INIT_SKILL" ]]; then
  # User specified an existing init skill — wire it up
  sed -i.bak "s|<your-init-skill>|$INIT_SKILL|g" "$SKILL_FILE"
  echo "  ✅ Wired init skill: $INIT_SKILL"
else
  # No init skill specified — install bundled fallback `planner-init`
  # so /planner run has SOMETHING to load project context with.
  cp "$SOURCE_DIR/examples/planner-init.example.md" "$TARGET/.claude/commands/planner-init.md"
  sed -i.bak "s|<your-init-skill>|planner-init|g" "$SKILL_FILE"
  echo "  ✅ Installed fallback init skill: planner-init (.claude/commands/planner-init.md)"
  echo "     ℹ️  Replace it later with a richer one if needed."
fi

rm -f "$SKILL_FILE.bak"
echo "  ✅ Customized placeholders"

# ─────────────────────────────────────────────────────────
# Step 3: Settings + CLAUDE.md hints
# ─────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅  Files installed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝  Manual steps remaining:"
echo ""
echo "1.  Wire hooks in $TARGET/.claude/settings.json (merge):"
echo ""
cat "$SOURCE_DIR/examples/settings.example.json" | sed 's/^/      /'
echo ""
echo "2.  Append planning section to $TARGET/CLAUDE.md:"
echo "      cat $SOURCE_DIR/examples/CLAUDE.example.md >> $TARGET/CLAUDE.md"
echo ""
echo "3.  Open Claude Code at $TARGET, then:"
echo "      /planner setup"
echo "      /planner <feature description>"
echo ""
echo "Docs: https://github.com/$REPO_OWNER/$REPO_NAME"
echo ""
