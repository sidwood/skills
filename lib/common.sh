# shellcheck shell=bash
# Shared configuration and helpers for install.sh and uninstall.sh.
# Source this file; do not execute it directly.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$CLAUDE_HOME/skills}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="${CODEX_SKILLS_DIR:-$CODEX_HOME/skills}"

# Repository entries that Stow must not symlink into the skills targets.
STOW_IGNORES=(
  --ignore='README\.md'
  --ignore='AGENTS\.md'
  --ignore='install\.sh'
  --ignore='uninstall\.sh'
  --ignore='lib'
  --ignore='tests'
  --ignore='\.claude'
  --ignore='\.git'
  --ignore='\.githooks'
  --ignore='\.markdownlint\.json'
  --ignore='\.vscode'
)

# Skills that were renamed or removed; their stale links should be cleaned up.
LEGACY_SKILLS=(
  write-a-prd
  prd-to-issues
  write-a-skill
  grill-me
  caveman
)

# Remove a symlink only when it still points at the expected repository target.
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
      if ! resolved_dir="$(cd "$(dirname "$link_path")" && cd "$(dirname "$link_target")" 2>/dev/null && pwd -P)"; then
        echo "Warning: could not resolve symlink target for '$link_path'; skipping." >&2
        return 0
      fi
      resolved_target="$resolved_dir/$(basename "$link_target")"
      ;;
  esac

  if [ "$resolved_target" = "$expected_target" ]; then
    rm "$link_path"
  fi

  return 0
}

# Ensure GNU Stow is available, otherwise exit with guidance.
require_stow() {
  if ! command -v stow &>/dev/null; then
    echo "Error: GNU Stow is required but not installed." >&2
    echo "Install it with: brew install stow (macOS) or apt install stow (Debian/Ubuntu)" >&2
    exit 1
  fi
}

# Run Stow for both the Claude and Codex skills directories.
# Extra arguments (e.g. -D to delete) are passed through to Stow.
stow_skills() {
  local target
  for target in "$CLAUDE_SKILLS_DIR" "$CODEX_SKILLS_DIR"; do
    stow -d "$REPO_DIR/.." -t "$target" "${STOW_IGNORES[@]}" "$@" skills
  done
}

# Remove stale links left behind by renamed or removed skills.
remove_legacy_links() {
  local skill

  # A legacy link created before .claude was ignored by Stow.
  if [ -d "$REPO_DIR/.claude" ]; then
    remove_link_if_target "$CLAUDE_SKILLS_DIR/.claude" "$(cd "$REPO_DIR/.claude" && pwd -P)"
    remove_link_if_target "$CODEX_SKILLS_DIR/.claude" "$(cd "$REPO_DIR/.claude" && pwd -P)"
  fi

  for skill in "${LEGACY_SKILLS[@]}"; do
    remove_link_if_target "$CLAUDE_SKILLS_DIR/$skill" "$REPO_DIR/$skill"
    remove_link_if_target "$CODEX_SKILLS_DIR/$skill" "$REPO_DIR/$skill"
  done
}
