#!/usr/bin/env bash
set -euo pipefail

# Run the install/uninstall test suite. Requires `bats` and GNU `stow`.
#
#   ./tests/run.sh

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

for dep in bats stow; do
  if ! command -v "$dep" &>/dev/null; then
    echo "Error: '$dep' is required to run the tests." >&2
    echo "Install it with: apt install $dep (Debian/Ubuntu) or brew install $dep (macOS)" >&2
    exit 1
  fi
done

exec bats "$TESTS_DIR"
