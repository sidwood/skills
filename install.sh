#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

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
