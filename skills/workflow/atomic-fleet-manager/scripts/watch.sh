#!/usr/bin/env bash
# Block until any agent terminal of the fleet but the caller's own changes
# state (a harness, the QA agent, a one-off agent of any name), then print
# what changed and the full status. Run it in the background; its exit is
# the wake-up. Re-arm it after handling each event.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: watch.sh [--space ID] [--interval SECONDS] [--timeout SECONDS]

  --space ID          The fleet's GUI space (default: the caller's own;
                      --workspace is accepted as the old name)
  --interval SECONDS  Fallback poll interval (default: 60)
  --timeout SECONDS   Give up and exit 0 with "NO CHANGE" after this long
                      (default: 0, wait indefinitely)

A change is a terminal appearing, disappearing or moving between working,
blocked and at-rest. "idle" and "done" both count as at-rest, so a terminal
drifting between them does not wake the watcher.

The watcher follows Herdr Core's events (hc events), so a terminal that
stops or blocks is reported within seconds, on this machine or another one:
a Cursor writer or reviewer finishing its turn, an Atomic run ending. A
terminal that starts working is reported only once it has stayed working
for the interval, so a harness answering a ping does not wake the fleet
manager twice. The interval is also the fallback poll for what no event
announces: a run that pauses or quits inside a terminal that stays at rest,
and a headless harness writing its result.
USAGE
}

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$here/fleet-hc.sh"
fleet_need_hc

space="" interval=60 timeout=0
while [ $# -gt 0 ]; do
  case "$1" in
    --space|--workspace) space="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$space" ] || space="$(fleet_space)"
[ -n "$space" ] || { echo "Error: no GUI space; run inside an hc terminal of the fleet or pass --space." >&2; exit 1; }
project="$(fleet_project "$space")"
status="$here/status.sh"

snapshot() {
  # name<TAB>state, with idle and done folded together.
  FLEET_PROJECT="$project" "$status" "$space" | cut -f1,3 | sed -E 's/	(idle|done)$/	at-rest/' | sort
}

# Wait for an event from a fleet terminal, or for the interval.
trigger=""
pause() {
  local exclude=()
  [ -z "${HC_TERMINAL_ID:-}" ] || exclude=(--exclude "$HC_TERMINAL_ID")
  if trigger="$(python3 "$FLEET_HC_PY" wait --space "$space" --project "$project" --timeout "$interval" ${exclude[@]+"${exclude[@]}"} 2>/dev/null)"; then
    # Give the agent a moment to settle into the state it announced.
    sleep 2
    return 0
  fi
  trigger="poll"
}

# True when the change cannot wait: a terminal opened or closed, or one
# stopped or blocked. False when terminals have only started working.
urgent() { # snapshot
  [ "$(printf '%s\n' "$base" | cut -f1)" = "$(printf '%s\n' "$1" | cut -f1)" ] || return 0
  # diff exits 1 when the snapshots differ, which pipefail would report as
  # "not urgent"; only the last grep's answer counts.
  { diff <(printf '%s\n' "$base") <(printf '%s\n' "$1") || true; } | grep -E '^> ' | grep -qv $'\tworking$'
}

base="$(snapshot)"
[ -n "$base" ] || { echo "Error: no agent terminals found for space $space (project $project)." >&2; exit 1; }

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
      FLEET_PROJECT="$project" "$status" "$space"
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
