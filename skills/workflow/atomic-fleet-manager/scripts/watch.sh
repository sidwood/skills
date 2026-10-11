#!/usr/bin/env bash
# Block until any agent tab but the caller's own changes state (a harness,
# the QA agent, a one-off agent in a tab of any name), then print what
# changed and the full status. Run it in the background; its exit is the
# wake-up. Re-arm it after handling each event.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: watch.sh [--workspace ID] [--interval SECONDS] [--timeout SECONDS]

  --workspace ID      Herdr workspace (default: $HERDR_WORKSPACE_ID)
  --interval SECONDS  Fallback poll interval (default: 60)
  --timeout SECONDS   Give up and exit 0 with "NO CHANGE" after this long
                      (default: 0, wait indefinitely)

A change is a tab appearing, disappearing or moving between working,
blocked and at-rest. "idle" and "done" both count as at-rest, so a tab
drifting between them does not wake the watcher.

The watcher subscribes to Herdr's agent events, so a tab that stops or
blocks is reported within seconds: a Cursor writer or reviewer finishing
its turn, an Atomic run ending or pausing. A tab that starts working is
reported only once it has stayed working for the interval, so a harness
answering a ping does not wake the fleet manager twice. The interval is
also the fallback poll for what Herdr does not announce: a tab opening or
closing, and a headless harness writing its result.
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

here="$(cd "$(dirname "$0")" && pwd)"
status="$here/status.sh"

snapshot() {
  # label<TAB>state, with idle and done folded together.
  "$status" "$workspace" | cut -f1,3 | sed -E 's/	(idle|done)$/	at-rest/' | sort
}

# Every pane in the workspace but this one: a pair has two, and a state
# change in any of them is worth a fresh look at the fleet.
watched_panes() {
  herdr pane list --workspace "$workspace" 2>/dev/null | SELF="${HERDR_PANE_ID:-}" python3 -c '
import json, os, sys
for pane in json.load(sys.stdin)["result"]["panes"]:
    if pane["pane_id"] != os.environ["SELF"]:
        print(pane["pane_id"])' 2>/dev/null || true
}

# Wait for Herdr to announce an agent changing state, or for the interval.
trigger=""
pause() {
  local panes
  panes="$(watched_panes)"
  if [ -n "$panes" ]; then
    # shellcheck disable=SC2086
    if trigger="$(python3 "$here/herdr-wait.py" --timeout "$interval" $panes 2>/dev/null)"; then
      # Give the agent a moment to settle into the state it announced.
      case "$trigger" in EVENT*) sleep 2 ;; esac
      return 0
    fi
  fi
  trigger="poll"
  sleep "$interval"
}

# True when the change cannot wait: a tab opened or closed, or a tab stopped
# or blocked. False when tabs have only started working.
urgent() { # snapshot
  [ "$(printf '%s\n' "$base" | cut -f1)" = "$(printf '%s\n' "$1" | cut -f1)" ] || return 0
  # diff exits 1 when the snapshots differ, which pipefail would report as
  # "not urgent"; only the last grep's answer counts.
  { diff <(printf '%s\n' "$base") <(printf '%s\n' "$1") || true; } | grep -E '^> ' | grep -qv $'\tworking$'
}

base="$(snapshot)"
[ -n "$base" ] || { echo "Error: no agent tabs found in workspace $workspace." >&2; exit 1; }

began=$SECONDS
started_at=""
while true; do
  pause
  # An empty read is a failed poll, not a change: keep waiting.
  now="$(snapshot || true)"
  if [ -n "$now" ] && [ "$now" != "$base" ]; then
    if urgent "$now" || { [ -n "$started_at" ] && [ $((SECONDS - started_at)) -ge "$interval" ]; }; then
      echo "CHANGED at $(date +%H:%M)"
      diff <(printf '%s\n' "$base") <(printf '%s\n' "$now") | grep -E '^[<>]' |
        sed -E 's/^< /was: /; s/^> /now: /' || true
      echo "trigger: ${trigger:-poll} at $(date +%H:%M:%S)"
      echo "--- status"
      "$status" "$workspace"
      exit 0
    fi
    [ -n "$started_at" ] || started_at=$SECONDS
  else
    started_at=""
  fi
  if [ "$timeout" -gt 0 ] && [ $((SECONDS - began)) -ge "$timeout" ]; then
    echo "NO CHANGE after $((SECONDS - began))s"
    exit 0
  fi
done
