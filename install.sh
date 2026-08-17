#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Use the repository-managed commit-message checks in a Git checkout. Archives
# can still install the skills, but have no repository in which to enable it.
if git -C "$REPO_DIR" rev-parse --git-dir &>/dev/null; then
  git -C "$REPO_DIR" config core.hooksPath .githooks
fi

require_stow

# Create skills target directories.
mkdir -p "$CLAUDE_SKILLS_DIR"
mkdir -p "$CODEX_SKILLS_DIR"

# Symlink repo skills into Claude and Codex.
# shellcheck disable=SC2119 # no extra Stow flags needed when installing
stow_skills

remove_legacy_links

# Symlink AGENTS.md as ~/.claude/CLAUDE.md
ln -sf "$REPO_DIR/AGENTS.md" "$CLAUDE_HOME/CLAUDE.md"

echo "Skills installed successfully."
