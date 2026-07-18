#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_stow

# Remove repo skill symlinks from Claude and Codex.
mkdir -p "$CLAUDE_SKILLS_DIR"
mkdir -p "$CODEX_SKILLS_DIR"

stow_skills -D

remove_legacy_links

# Remove AGENTS.md symlink if it points to this repo
if [ -L "$CLAUDE_HOME/CLAUDE.md" ] && [ "$(readlink "$CLAUDE_HOME/CLAUDE.md")" = "$REPO_DIR/AGENTS.md" ]; then
  rm "$CLAUDE_HOME/CLAUDE.md"
fi

# Remove skills directory if empty
rmdir "$CLAUDE_SKILLS_DIR" 2>/dev/null || true
rmdir "$CODEX_SKILLS_DIR" 2>/dev/null || true

echo "Skills uninstalled successfully."
