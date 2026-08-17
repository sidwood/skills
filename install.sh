#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$CLAUDE_HOME/skills}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$CODEX_HOME/skills}"

# Use the repository-managed commit-message checks in a Git checkout. Archives
# can still install the skills, but have no repository in which to enable it.
if git -C "$REPO_DIR" rev-parse --git-dir &>/dev/null; then
  git -C "$REPO_DIR" config core.hooksPath .githooks
fi

remove_link_if_target() {
  local link_path="$1"
  local expected_target="$2"
  local link_target
  local resolved_dir
  local resolved_target

  [ -L "$link_path" ] || return 0

  link_target="$(readlink "$link_path")"
  case "$link_target" in
    /*)
      resolved_target="$link_target"
      ;;
    *)
      resolved_dir="$(cd "$(dirname "$link_path")" && cd "$(dirname "$link_target")" && pwd -P)"
      resolved_target="$resolved_dir/$(basename "$link_target")"
      ;;
  esac

  if [ "$resolved_target" = "$expected_target" ]; then
    rm "$link_path"
  fi

  return 0
}

# Check for GNU Stow
if ! command -v stow &>/dev/null; then
  echo "Error: GNU Stow is required but not installed." >&2
  echo "Install it with: brew install stow (macOS) or apt install stow (Debian/Ubuntu)" >&2
  exit 1
fi

# Create skills target directories
mkdir -p "$CLAUDE_SKILLS_DIR"
mkdir -p "$CODEX_SKILLS_DIR"

# Symlink repo skills into Claude and Codex.
stow -d "$REPO_DIR/.." -t "$CLAUDE_SKILLS_DIR" \
  --ignore='README\.md' \
  --ignore='AGENTS\.md' \
  --ignore='install\.sh' \
  --ignore='uninstall\.sh' \
  --ignore='\.claude' \
  skills

stow -d "$REPO_DIR/.." -t "$CODEX_SKILLS_DIR" \
  --ignore='README\.md' \
  --ignore='AGENTS\.md' \
  --ignore='install\.sh' \
  --ignore='uninstall\.sh' \
  --ignore='\.claude' \
  skills

# Remove a legacy link created before .claude was ignored by Stow.
if [ -d "$REPO_DIR/.claude" ]; then
  remove_link_if_target "$CLAUDE_SKILLS_DIR/.claude" "$(cd "$REPO_DIR/.claude" && pwd -P)"
  remove_link_if_target "$CODEX_SKILLS_DIR/.claude" "$(cd "$REPO_DIR/.claude" && pwd -P)"
fi

# Remove legacy links from skills that were renamed or removed.
remove_link_if_target "$CLAUDE_SKILLS_DIR/write-a-prd" "$REPO_DIR/write-a-prd"
remove_link_if_target "$CODEX_SKILLS_DIR/write-a-prd" "$REPO_DIR/write-a-prd"
remove_link_if_target "$CLAUDE_SKILLS_DIR/prd-to-issues" "$REPO_DIR/prd-to-issues"
remove_link_if_target "$CODEX_SKILLS_DIR/prd-to-issues" "$REPO_DIR/prd-to-issues"
remove_link_if_target "$CLAUDE_SKILLS_DIR/write-a-skill" "$REPO_DIR/write-a-skill"
remove_link_if_target "$CODEX_SKILLS_DIR/write-a-skill" "$REPO_DIR/write-a-skill"
remove_link_if_target "$CLAUDE_SKILLS_DIR/grill-me" "$REPO_DIR/grill-me"
remove_link_if_target "$CODEX_SKILLS_DIR/grill-me" "$REPO_DIR/grill-me"
remove_link_if_target "$CLAUDE_SKILLS_DIR/caveman" "$REPO_DIR/caveman"
remove_link_if_target "$CODEX_SKILLS_DIR/caveman" "$REPO_DIR/caveman"

# Symlink AGENTS.md as ~/.claude/CLAUDE.md
ln -sf "$REPO_DIR/AGENTS.md" "$CLAUDE_HOME/CLAUDE.md"

echo "Skills installed successfully."
