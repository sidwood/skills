#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check for GNU Stow
if ! command -v stow &>/dev/null; then
  echo "Error: GNU Stow is required but not installed." >&2
  exit 1
fi

# Remove stow symlinks
stow -d "$REPO_DIR/.." -t ~/.claude/skills --ignore='README\.md' --ignore='AGENTS\.md' -D skills

# Remove AGENTS.md symlink if it points to this repo
if [ -L ~/.claude/CLAUDE.md ] && [ "$(readlink ~/.claude/CLAUDE.md)" = "$REPO_DIR/AGENTS.md" ]; then
  rm ~/.claude/CLAUDE.md
fi

# Remove skills directory if empty
rmdir ~/.claude/skills 2>/dev/null || true

echo "Skills uninstalled successfully."
