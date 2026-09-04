#!/usr/bin/env bash
# cspell:ignore isinstance rsplit rstrip
# Deterministic orchestrator self-evaluation. Run it at EVERY wake (monitor
# event, watchdog tick, or shift start) and answer three questions against the
# output: is the fleet moving correctly, what can be improved, what efficiency
# is available. Every finding becomes an action in the same turn.
#
# Alarm words are grep-able on purpose: RECIPE-DRIFT, MONITOR-DOWN,
# BOARD-STALE, VELOCITY-STALL, STALE-BLOCKERS, QUEUE-DRIFT, ORPHANED,
# CAPACITY-STALL, CAPACITY-RECOVERY-FAILED. See references/self-eval.md for
# the action each one demands.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$SCRIPT_DIR/fleet-env.sh"

usage() {
  cat <<'EOF'
Usage: self-eval.sh [--help]

Required bindings: FLEET_SESSION, FLEET_SEED.
State and fleet config default to <seed>/temp/fleet/.
Optional: FLEET_BOARD, FLEET_DEADLINE ("YYYY-MM-DD HH:MM" local time),
FLEET_COORDINATOR, phase-set overrides, staleness thresholds, FLEET_ENV.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '') ;;
  *)
    usage >&2
    exit 2
    ;;
esac

fleet_env_load || exit 2
fleet_env_require FLEET_SESSION FLEET_SEED FLEET_CONFIG FLEET_STATE_DIR || exit 2
touch "$FLEET_SWEPT"

now="$(date +%s)"
echo "=== SELF-EVAL $(date '+%Y-%m-%d %H:%M:%S %Z') ==="

echo "--- recipe catalog ---"
fleet_cli="$SCRIPT_DIR/../../fleet-coordinator/scripts/fleet.py"
if recipe_check="$(python3 "$fleet_cli" --config "$FLEET_CONFIG" recipes check 2>&1)"; then
  echo "$recipe_check"
else
  echo "$recipe_check"
fi

if [ -n "${FLEET_DEADLINE:-}" ]; then
  python3 - "$FLEET_DEADLINE" "$now" <<'PYTHON'
import datetime, sys

try:
    target = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%d %H:%M').timestamp()
except ValueError:
    print(f'deadline: unparsable FLEET_DEADLINE {sys.argv[1]!r} (want "YYYY-MM-DD HH:MM")')
else:
    left = int(target) - int(sys.argv[2])
    sign = '' if left >= 0 else '-'
    left = abs(left)
    print(f'deadline: {sign}{left // 3600}h {(left % 3600) // 60}m to {sys.argv[1]}')
PYTHON
fi

echo "--- lanes ---"
herdr agent list --session "$FLEET_SESSION" 2>/dev/null |
  python3 -c '
import json, sys

config_path, pending_path, coordinator, now_arg = sys.argv[1:]


def lane_from_event(event_id):
    return event_id.rsplit("@", 1)[0] if "@" in event_id else event_id


def integer(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


try:
    agents = json.load(sys.stdin)["result"]["agents"]
    with open(config_path) as config_file:
        config = json.load(config_file)
    acknowledged_lanes = {
        event.get("agent")
        for stream in config.get("streams", [])
        for event in stream.get("events", [])
        if isinstance(event, dict) and event.get("eventId") and event.get("agent")
    }

    pending = []
    pending_lanes = set()
    try:
        with open(pending_path) as pending_file:
            for raw in pending_file:
                fields = raw.rstrip("\n").split("\t")
                if len(fields) < 2 or not fields[0]:
                    continue
                fields.extend([""] * (6 - len(fields)))
                event_id, lane, _state, sent, attempts, target = fields[:6]
                lane = lane or lane_from_event(event_id)
                pending_lanes.add(lane)
                sent_at = integer(sent)
                age = "unsent" if sent_at <= 0 else f"{max(0, int(now_arg) - sent_at)}s"
                target = target or "?"
                pending.append(
                    f"{event_id}[{target},age={age},attempts={integer(attempts)}]"
                )
    except FileNotFoundError:
        pass

    handled_lanes = acknowledged_lanes | pending_lanes
    working = [a.get("name") or "?" for a in agents if a["agent_status"] == "working"]
    settled = []
    for agent in agents:
        name = agent.get("name") or "?"
        seq = agent.get("state_change_seq", 0)
        event_id = f"{name}@{seq}"
        if (agent["agent_status"] in ("done", "idle")
                and name not in {coordinator, "?"} and name not in handled_lanes):
            settled.append(event_id)
    blocked = [a.get("name") or "?" for a in agents if a["agent_status"] == "blocked"]
    print(f"working={len(working)}: " + ", ".join(working))
    print(f"settled-unswept={len(settled)}: " + (", ".join(settled) or "none"))
    print(f"pending-delivery={len(pending)}: " + (", ".join(sorted(pending)) or "none"))
    if blocked:
        print("blocked=" + ", ".join(blocked) + " - a dialog may be waiting")
except Exception as exc:
    print("LANE-READ-FAILED", exc)' \
    "$FLEET_CONFIG" "$FLEET_PENDING" "$FLEET_COORDINATOR" "$now"

echo "--- git ---"
seed_tip="$(git -C "$FLEET_SEED" log --oneline -1 2>/dev/null || echo 'seed-read-failed')"
branch="$(git -C "$FLEET_SEED" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
unpushed="$(git -C "$FLEET_SEED" rev-list "@{upstream}..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
echo "seed[$branch]=$seed_tip | unpushed=$unpushed"

echo "--- CI on the pushed tip ---"
if command -v gh > /dev/null 2>&1; then
  tip="$(git -C "$FLEET_SEED" rev-parse "@{upstream}" 2>/dev/null || echo '')"
  if [ -n "$tip" ]; then
    (cd "$FLEET_SEED" && gh run list --commit "$tip" --json name,status,conclusion 2>/dev/null) |
      python3 -c "
import json, sys
try:
    runs = json.load(sys.stdin)
    print('; '.join(f\"{r['name']}:{r.get('conclusion') or r['status']}\" for r in runs)
          or 'no runs for the pushed tip')
except Exception:
    print('ci-read-failed')"
  else
    echo "no upstream configured; skipping CI read"
  fi
else
  echo "gh not installed; skipping CI read"
fi

mtime() { python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$1"; }

echo "--- watcher health ---"
if [ -f "$FLEET_HEARTBEAT" ]; then
  age=$((now - $(cat "$FLEET_HEARTBEAT")))
  if [ "$age" -gt "$FLEET_MONITOR_STALE_SECONDS" ]; then
    echo "MONITOR-DOWN: settle monitor heartbeat ${age}s stale - relaunch fleet-monitor.sh now"
  else
    echo "settle monitor heartbeat ${age}s (healthy <= $FLEET_MONITOR_STALE_SECONDS)"
  fi
else
  echo "MONITOR-DOWN: no heartbeat file - fleet-monitor.sh was never armed this shift"
fi

if [ -f "$FLEET_PUSH_MARKER" ]; then
  pushed="$(cut -c1-8 < "$FLEET_PUSH_MARKER")"
  if [ -f "$FLEET_CI_HEARTBEAT" ]; then
    ci_age=$((now - $(cat "$FLEET_CI_HEARTBEAT")))
    if [ "$ci_age" -gt "$FLEET_CI_STALE_SECONDS" ]; then
      echo "MONITOR-DOWN: push $pushed in flight, CI watcher heartbeat ${ci_age}s stale - rearm ci-watch.sh $pushed"
    else
      echo "push $pushed in flight; CI watcher heartbeat ${ci_age}s (healthy <= $FLEET_CI_STALE_SECONDS)"
    fi
  else
    echo "MONITOR-DOWN: push $pushed in flight with no CI watcher - arm ci-watch.sh $pushed"
  fi
else
  echo "no push in flight"
fi

if [ -n "${FLEET_BOARD:-}" ]; then
  echo "--- board currency ---"
  if [ -f "$FLEET_BOARD" ]; then
    lag=$(($(mtime "$FLEET_CONFIG") - $(mtime "$FLEET_BOARD")))
    if [ "$lag" -gt "$FLEET_BOARD_STALE_SECONDS" ]; then
      echo "BOARD-STALE: board lags the fleet config by ${lag}s - pulse the coordinator to regenerate it"
    else
      echo "board lag ${lag}s behind the fleet config (healthy <= $FLEET_BOARD_STALE_SECONDS)"
    fi
  else
    echo "BOARD-STALE: board file missing at $FLEET_BOARD - pulse the coordinator"
  fi
fi

python3 - <<'PYTHON'
import collections, json, os, re, subprocess, time

config = json.load(open(os.environ['FLEET_CONFIG']))
streams = config.get('streams', [])
seed = os.environ['FLEET_SEED']
session = os.environ['FLEET_SESSION']


def tokens(name):
    return os.environ[name].split()


CLOSED = tokens('FLEET_CLOSED_PHASES')
QUEUED = tokens('FLEET_QUEUED_PHASES')
ACTIVE = tokens('FLEET_ACTIVE_PHASES')
BLOCKED = tokens('FLEET_BLOCKED_PHASES')


def phase_in(phase, group):
    # Phases carry cycle counters (review-2, bounce-1); match on the stem.
    return any(phase == t or phase.startswith(t + '-') for t in group)


print('--- streams ---')
counts = collections.Counter(s.get('phase', '?') for s in streams)
print(dict(counts))
open_streams = [s['ticket'] for s in streams if not phase_in(s.get('phase', '?'), CLOSED)]
print(f'open={len(open_streams)}:', ', '.join(open_streams[:20]))

print('--- backlog velocity ---')
log_path = os.environ['FLEET_VELOCITY_LOG']
window = int(os.environ['FLEET_VELOCITY_WINDOW_SECONDS'])
now = int(time.time())
try:
    rows = [line.split() for line in open(log_path).read().splitlines() if line.strip()]
except FileNotFoundError:
    rows = []
with open(log_path, 'a') as fh:
    fh.write(f'{now} {len(open_streams)}\n')
earlier = [r for r in rows if now - int(r[0]) >= window]
if not earlier:
    print(f'velocity baseline: open {len(open_streams)} (history warming up)')
else:
    was = earlier[-1]
    delta = int(was[1]) - len(open_streams)
    age_m = (now - int(was[0])) // 60
    if delta <= 0:
        print(f'VELOCITY-STALL: open backlog {len(open_streams)} has not decreased in '
              f'{age_m}m (was {was[1]}) - find the bottleneck and pulse the coordinator')
    else:
        print(f'velocity ok: open {len(open_streams)}, down {delta} in the last {age_m}m')

print('--- blocked column ---')
phase_of = {s['ticket']: s.get('phase', '?') for s in streams}
gated = [s for s in streams if phase_in(s.get('phase', '?'), BLOCKED)]
print(f'blocked or parked: {len(gated)}')
stale, clusters = [], collections.defaultdict(list)
for s in gated:
    for blocker in s.get('blockedBy') or []:
        blocker = str(blocker)
        match = re.match(r'([A-Za-z0-9.\-]+)', blocker)
        if match and phase_in(phase_of.get(match.group(1), '?'), CLOSED):
            stale.append(f"{s['ticket']} (blocker {match.group(1)} is already "
                         f"{phase_of[match.group(1)]})")
        clusters[blocker[:55]].append(s['ticket'])
if stale:
    print('STALE-BLOCKERS (ready to dispatch now - order the dispatch):')
    for item in stale:
        print('  *', item)
top = sorted(clusters.items(), key=lambda kv: -len(kv[1]))[:3]
if top:
    print('top unblock levers:', '; '.join(f'{k!r} frees {len(v)}' for k, v in top))

print('--- queue reconciliation (computed, never remembered) ---')


def on_seed(sha):
    if not sha:
        return None
    return subprocess.run(['git', '-C', seed, 'merge-base', '--is-ancestor', sha, 'HEAD'],
                          capture_output=True).returncode == 0


try:
    agents = json.loads(subprocess.run(['herdr', 'agent', 'list', '--session', session],
                                       capture_output=True, text=True).stdout)
    lane_names = {a.get('name') for a in agents['result']['agents'] if a.get('name')}
except Exception:
    lane_names = None

queue, drift = [], []
for s in streams:
    ticket, phase = s.get('ticket'), s.get('phase', '?')
    tip = s.get('approvedTip') or s.get('tip')
    if phase_in(phase, QUEUED):
        if on_seed(tip):
            drift.append(f"QUEUE-DRIFT: {ticket} phase '{phase}' but tip {str(tip)[:8]} is "
                         'already on the seed - have the coordinator re-phase it to landed')
        else:
            queue.append(ticket)
    elif phase_in(phase, CLOSED):
        landed = s.get('landedTip') or tip
        if landed and on_seed(landed) is False and on_seed(s.get('tip')) is False:
            drift.append(f"QUEUE-DRIFT: {ticket} phase '{phase}' but no recorded tip is on the "
                         'seed - landedTip must be the post-rebase seed SHA')
    elif phase_in(phase, ACTIVE) and lane_names is not None:
        expected_lanes = {
            record.get('name')
            for record in s.get('agents', {}).values()
            if isinstance(record, dict)
            and record.get('name')
            and record.get('dispatchState', '') in {'', 'prompting', 'active'}
        }
        if not expected_lanes.intersection(lane_names):
            drift.append(f"ORPHANED: {ticket} phase '{phase}' with no matching lane - "
                         're-dispatch it or re-phase it')

    if phase == 'hold':
        for event in s.get('events', []):
            if event.get('resolutionClass') != 'capacity':
                continue
            error = event.get('recoveryError')
            if error:
                drift.append(
                    f"CAPACITY-RECOVERY-FAILED: {ticket} after {event.get('agent')} - "
                    f"{error}"
                )
                continue
            if event.get('replacementAgent'):
                continue
            role = event.get('role')
            current = s.get('agents', {}).get(role, {})
            if current.get('name') != event.get('agent'):
                drift.append(
                    f"CAPACITY-RECOVERY-FAILED: {ticket} after {event.get('agent')} - "
                    f"replacement {current.get('name') or '?'} stopped at "
                    f"{current.get('dispatchState') or 'unknown'}"
                )
            else:
                drift.append(
                    f"CAPACITY-STALL: {ticket} has no replacement after "
                    f"{event.get('agent')} exhausted {event.get('usagePool')} - "
                    'retry the exact capture event'
                )

print('train queue:', ', '.join(queue) if queue else '(empty)')
for line in drift:
    print(' *', line)
if not drift:
    print('no queue drift')
PYTHON

echo "=== END SELF-EVAL ==="
