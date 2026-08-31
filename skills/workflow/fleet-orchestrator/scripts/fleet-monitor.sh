#!/usr/bin/env bash
# Persistent fleet settle monitor. It never exits on an event.
#
#  - ROUTINE lane settles are handled here: the sweep prompt goes straight to
#    the coordinator, the lane is appended to the swept ledger, and the event
#    is logged. The orchestrator's main loop is not woken.
#  - Only judgment events reach stdout, which is what wakes the orchestrator:
#    verdict-bearing lane settles, blocked lanes, vanished unswept lanes, seed
#    moves, coordinator stalls, and unreadable inventories.
#  - A heartbeat file is written every poll; self-eval.sh reads it to prove the
#    monitor is alive.
#
# Launch it ONCE through a persistent monitor facility. Never with `&`: a
# background shell job is orphaned by the harness, stops writing heartbeats,
# and nobody notices. See references/monitor-design.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$SCRIPT_DIR/fleet-env.sh"

usage() {
  cat <<'EOF'
Usage: fleet-monitor.sh [--once] [--help]

  --once  run a single poll and exit (arming check; not a substitute for the
          persistent run)

Required bindings: FLEET_SESSION, FLEET_SEED, FLEET_STATE_DIR.
Optional: FLEET_COORDINATOR, FLEET_POLL_SECONDS, FLEET_VERDICT_LANE_GLOBS,
FLEET_SWEEP_INSTRUCTION, FLEET_STALL_SECONDS, FLEET_IDLE_SECONDS,
FLEET_PULSE_INTERVAL_SECONDS, FLEET_ENV.
EOF
}

once=0
while [ $# -gt 0 ]; do
  case "$1" in
    --once) once=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

fleet_env_load || exit 2
fleet_env_require FLEET_SESSION FLEET_SEED FLEET_STATE_DIR || exit 2
touch "$FLEET_SWEPT" "$FLEET_LOG"

prev=""
prev_seed=""
coord_idle_since=0
last_pulse=0
coord_rev_seen=""
coord_rev_time=0
blocked_reported=" "

log() { echo "$(date '+%H:%M:%S') $*" >> "$FLEET_LOG"; }

# One line per agent: name|status|revision, sorted so the string can be
# diffed against the previous poll.
snapshot() {
  herdr agent list --session "$FLEET_SESSION" 2>&1 | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    rows = [f\"{a.get('name') or '?'}|{a['agent_status']}|{a.get('revision', 0)}\"
            for a in data['result']['agents']]
    print(';'.join(sorted(rows)) or 'EMPTY')
except Exception as exc:
    print(f'PARSE-ERROR:{exc}')"
}

# Routine settle: act now, do not wake the orchestrator.
sweep() {
  herdr agent prompt "$FLEET_COORDINATOR" --session "$FLEET_SESSION" \
    "SWEEP: $1 settled -> $2. $FLEET_SWEEP_INSTRUCTION" > /dev/null 2>&1
  echo "$1" >> "$FLEET_SWEPT"
  log "swept $1 ($2) direct to coordinator"
}

settle() {
  if fleet_is_verdict_lane "$1"; then
    echo "WAKE: verdict lane $1 settled -> $2"
  else
    sweep "$1" "$2"
  fi
}

# Lanes that settled while no monitor was armed still need handling, so the
# first poll treats every unswept settled lane as a fresh event.
baseline() {
  local name state
  while IFS='|' read -r name state _; do
    [ "$name" = "$FLEET_COORDINATOR" ] && continue
    case "$state" in
      done | idle)
        grep -qx "$name" "$FLEET_SWEPT" && continue
        if fleet_is_verdict_lane "$name"; then
          echo "WAKE: verdict lane $name settled (baseline)"
        else
          sweep "$name" "$state"
        fi
        ;;
    esac
  done < <(echo "$1" | tr ';' '\n')
}

transitions() {
  FLEET_SWEPT="$FLEET_SWEPT" FLEET_COORDINATOR="$FLEET_COORDINATOR" \
    python3 - "$1" "$2" <<'PYTHON'
import os, sys


def parse(text):
    table = {}
    for row in text.split(';'):
        parts = row.split('|')
        if len(parts) == 3:
            table[parts[0]] = (parts[1], int(parts[2]))
    return table


old, new = parse(sys.argv[1]), parse(sys.argv[2])
swept = open(os.environ['FLEET_SWEPT']).read().split()
coordinator = os.environ['FLEET_COORDINATOR']

for lane, (state, _rev) in new.items():
    was = old.get(lane)
    if lane == coordinator or lane in swept:
        continue
    if was and was[0] == 'working' and state in ('done', 'idle'):
        print(f'SETTLED:{lane} {state}')
    # Two consecutive blocked polls, not one: a single blocked reading is
    # usually a lane between turns, sustained blocked is a dialog waiting.
    if was and was[0] == 'blocked' and state == 'blocked':
        print(f'BLOCKED:{lane} blocked for 2+ polls - approval dialog waiting?')
    if not was:
        print(f'INFO:new lane {lane} ({state})')

for lane, (state, _rev) in old.items():
    if lane not in new and state in ('working', 'done') and lane not in swept:
        print(f'VANISHED:{lane} vanished (was {state}) - uncaptured teardown?')
PYTHON
}

# The coordinator is a lane too: a frozen revision while it reports working is
# a stall, and idleness with unprocessed settles is a dropped event.
coordinator_oversight() {
  local cur="$1" state rev now pending
  state="$(echo "$cur" | tr ';' '\n' | awk -F'|' -v c="$FLEET_COORDINATOR" '$1 == c { print $2 }')"
  rev="$(echo "$cur" | tr ';' '\n' | awk -F'|' -v c="$FLEET_COORDINATOR" '$1 == c { print $3 }')"
  now="$(date +%s)"
  [ -n "$state" ] || return 0

  if [ "$state" = working ]; then
    coord_idle_since=0
    if [ "$coord_rev_seen" = "$rev" ]; then
      if [ $((now - coord_rev_time)) -ge "$FLEET_STALL_SECONDS" ]; then
        echo "WAKE: COORDINATOR-STALL working with frozen revision $rev"
        coord_rev_time="$now"
      fi
    else
      coord_rev_seen="$rev"
      coord_rev_time="$now"
    fi
    return 0
  fi

  [ "$coord_idle_since" = 0 ] && coord_idle_since="$now"
  [ $((now - coord_idle_since)) -ge "$FLEET_IDLE_SECONDS" ] || return 0
  [ $((now - last_pulse)) -ge "$FLEET_PULSE_INTERVAL_SECONDS" ] || return 0
  pending="$(echo "$cur" | tr ';' '\n' |
    awk -F'|' -v c="$FLEET_COORDINATOR" '$2 == "done" && $1 != c { print $1 }' |
    grep -v -x -f "$FLEET_SWEPT" | tr '\n' ' ')"
  [ -n "$pending" ] || return 0
  herdr agent prompt "$FLEET_COORDINATOR" --session "$FLEET_SESSION" \
    "IDLE-PULSE: you have been idle with settled lanes unprocessed: $pending. Apply your event table." \
    > /dev/null 2>&1
  last_pulse="$now"
  log "idle-pulsed coordinator: $pending"
}

poll() {
  local cur seed_tip line kind rest lane state
  date +%s > "$FLEET_HEARTBEAT"
  cur="$(snapshot)"
  seed_tip="$(git -C "$FLEET_SEED" rev-parse --short HEAD 2>/dev/null || echo git-read-failed)"

  case "$cur" in
    PARSE-ERROR* | EMPTY)
      echo "WAKE: fleet inventory unreadable: $cur"
      return 0
      ;;
  esac

  if [ -z "$prev" ]; then
    baseline "$cur"
    prev="$cur"
    prev_seed="$seed_tip"
    return 0
  fi

  if [ "$seed_tip" != "$prev_seed" ]; then
    echo "WAKE: SEED-MOVED $prev_seed -> $seed_tip"
  fi

  while read -r line; do
    kind="${line%%:*}"
    rest="${line#*:}"
    case "$kind" in
      SETTLED)
        lane="${rest%% *}"
        state="${rest##* }"
        settle "$lane" "$state"
        ;;
      VANISHED) echo "WAKE: $rest" ;;
      BLOCKED)
        # Once per blocked episode. A lane stuck on a dialog for an hour is
        # one wake, and self-eval re-lists it at every later wake.
        lane="${rest%% *}"
        case "$blocked_reported" in
          *" $lane "*) log "$rest (already reported)" ;;
          *)
            echo "WAKE: $rest"
            blocked_reported="$blocked_reported$lane "
            ;;
        esac
        ;;
      INFO) log "$rest" ;;
    esac
  done < <(transitions "$prev" "$cur")

  # A lane that left blocked can raise the alarm again next time.
  for lane in $blocked_reported; do
    case ";$cur" in
      *";$lane|blocked|"*) ;;
      *) blocked_reported="${blocked_reported// $lane / }" ;;
    esac
  done

  coordinator_oversight "$cur"

  # The ledger is the deduplication key for sweeps; keep it bounded.
  if tail -300 "$FLEET_SWEPT" > "$FLEET_SWEPT.tmp" 2>/dev/null; then
    mv "$FLEET_SWEPT.tmp" "$FLEET_SWEPT"
  fi
  prev="$cur"
  prev_seed="$seed_tip"
}

while true; do
  poll
  [ "$once" = 1 ] && exit 0
  sleep "$FLEET_POLL_SECONDS"
done
