#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check for GNU Stow
if ! command -v stow &>/dev/null; then
  echo "Error: GNU Stow is required but not installed." >&2
  echo "Install it with: brew install stow (macOS) or apt install stow (Debian/Ubuntu)" >&2
  exit 1
fi

# Create skills target directory
mkdir -p ~/.claude/skills

# Symlink skills into ~/.claude/skills
stow -d "$REPO_DIR/.." -t ~/.claude/skills \
  --ignore='README\.md' \
  --ignore='AGENTS\.md' \
  --ignore='install\.sh' \
  --ignore='uninstall\.sh' \
  skills

# Symlink AGENTS.md as ~/.claude/CLAUDE.md
ln -sf "$REPO_DIR/AGENTS.md" ~/.claude/CLAUDE.md

echo "Skills installed successfully."
