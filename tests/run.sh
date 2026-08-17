#!/usr/bin/env bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v bats &>/dev/null; then
  echo "Error: 'bats' is required to run the tests." >&2
  echo "Install it with: brew install bats-core (macOS) or apt install bats (Debian/Ubuntu)" >&2
  exit 1
fi

exec bats "$TESTS_DIR"
