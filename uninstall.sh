#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

validate_skill_catalog

for skills_dir in "${SKILLS_TARGET_DIRS[@]}"; do
  remove_catalog_links_from_target "$skills_dir"
done

remove_legacy_links
remove_claude_instructions
unconfigure_hermes
remove_empty_skill_directories

echo "Skills uninstalled successfully."
