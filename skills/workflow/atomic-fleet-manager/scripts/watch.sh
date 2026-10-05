#!/usr/bin/env bash
# Block until a harness tab or the QA tab changes state, then print what
# changed and the full status. Run it in the background; its exit is the
# wake-up. Re-arm it after handling each event.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: watch.sh [--workspace ID] [--interval SECONDS] [--timeout SECONDS]

  --workspace ID      Herdr workspace (default: $HERDR_WORKSPACE_ID)
  --interval SECONDS  Poll interval (default: 60)
  --timeout SECONDS   Give up and exit 0 with "NO CHANGE" after this long
                      (default: 0, wait indefinitely)

A change is a tab appearing, disappearing or moving between working,
blocked and at-rest. "idle" and "done" both count as at-rest, so a tab
drifting between them does not wake the watcher.
USAGE
}

workspace="${HERDR_WORKSPACE_ID:-}" interval=60 timeout=0
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) workspace="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$workspace" ] || { echo "Error: no Herdr workspace; pass --workspace." >&2; exit 1; }

status="$(cd "$(dirname "$0")" && pwd)/status.sh"

snapshot() {
  # label<TAB>state, with idle and done folded together.
  "$status" "$workspace" | cut -f1,3 | sed -E 's/	(idle|done)$/	at-rest/' | sort
}

base="$(snapshot)"
[ -n "$base" ] || { echo "Error: no harness or QA tabs found in workspace $workspace." >&2; exit 1; }

waited=0
while true; do
  sleep "$interval"
  waited=$((waited + interval))
  # An empty read is a failed poll, not a change: keep waiting.
  now="$(snapshot || true)"
  if [ -n "$now" ] && [ "$now" != "$base" ]; then
    echo "CHANGED at $(date +%H:%M)"
    diff <(printf '%s\n' "$base") <(printf '%s\n' "$now") | grep -E '^[<>]' |
      sed -E 's/^< /was: /; s/^> /now: /' || true
    echo "--- status"
    "$status" "$workspace"
    exit 0
  fi
  if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
    echo "NO CHANGE after ${waited}s"
    exit 0
  fi
done
