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

# Remove skills directories only when empty. Leaving non-empty directories
# untouched is expected, but any other rmdir failure (e.g. permissions) should
# surface rather than be swallowed.
for skills_dir in "$CLAUDE_SKILLS_DIR" "$CODEX_SKILLS_DIR"; do
  if [ -d "$skills_dir" ] && [ -z "$(ls -A "$skills_dir")" ]; then
    rmdir "$skills_dir"
  fi
done

echo "Skills uninstalled successfully."
