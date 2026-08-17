#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Use the repository-managed commit-message checks in a Git checkout. Archives
# can still install the skills, but have no repository in which to enable it.
if git -C "$REPO_DIR" rev-parse --git-dir &>/dev/null; then
  git -C "$REPO_DIR" config core.hooksPath .githooks
fi

validate_skill_catalog
install_skill_links
remove_legacy_links
install_claude_instructions
configure_hermes

echo "Skills installed for Codex, Claude, Grok, Kimi, Cursor, OpenCode, Pi, and Hermes."
