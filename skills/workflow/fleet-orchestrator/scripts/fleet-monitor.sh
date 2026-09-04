#!/usr/bin/env bash
# cspell:ignore acked endswith fromisoformat isinstance monitorable rsplit unacked
# Persistent fleet settle monitor. It never exits on an event.
#
# Every settlement is queued durably before its coordinator prompt or
# orchestrator wake. An event is swept only after fleet.json contains its exact
# capture ID. Failed, swallowed, or missed deliveries remain pending and retry.
# Healthy polls write files only and produce no stdout or stderr.
#
# Launch this ONCE through a persistent monitor facility. Never with `&`: a
# background shell job can be orphaned by the harness. See
# references/monitor-design.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$SCRIPT_DIR/fleet-env.sh"

lock_handoff=0
lock_fd=""
if [ "${1:-}" = --_fleet-monitor-lock-held ]; then
  lock_handoff=1
  lock_fd="${_FLEET_MONITOR_LOCK_FD:-}"
  shift
fi
usage() {
  cat <<'EOF'
Usage: fleet-monitor.sh [--once] [--help]

  --once  run a single poll and exit (arming check; not a substitute for the
          persistent run)

Required bindings: FLEET_SESSION, FLEET_SEED.
State and fleet config default to <seed>/temp/fleet/.
Optional: FLEET_COORDINATOR, FLEET_POLL_SECONDS,
FLEET_ACK_TIMEOUT_SECONDS, FLEET_TEARDOWN_GRACE_SECONDS,
FLEET_VERDICT_LANE_GLOBS,
FLEET_SWEEP_INSTRUCTION, FLEET_STALL_SECONDS, FLEET_ENV.
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

if [ "$lock_handoff" -eq 0 ]; then
  unset _FLEET_MONITOR_LOCK_FD _FLEET_MONITOR_LOCK_PATH
  fleet_env_load || exit 2
  fleet_env_require FLEET_SESSION FLEET_SEED FLEET_STATE_DIR FLEET_CONFIG \
    FLEET_MONITOR_LOCK_FILE || exit 2
  if [ "$once" -eq 1 ]; then
    exec python3 "$SCRIPT_DIR/fleet-lock-exec.py" \
      "$FLEET_MONITOR_LOCK_FILE" "$SCRIPT_DIR/fleet-monitor.sh" --once
  fi
  exec python3 "$SCRIPT_DIR/fleet-lock-exec.py" \
    "$FLEET_MONITOR_LOCK_FILE" "$SCRIPT_DIR/fleet-monitor.sh"
fi

# The lock helper already resolved and exported the environment. Loading an
# env file again could repeat its side effects, so only validate the handoff.
fleet_env_require FLEET_SESSION FLEET_SEED FLEET_STATE_DIR FLEET_CONFIG \
  FLEET_MONITOR_LOCK_FILE || exit 2
case "$lock_fd" in
  '' | *[!0-9]*)
    echo "fleet-monitor: invalid lock handoff" >&2
    exit 2
    ;;
esac
if [ "${_FLEET_MONITOR_LOCK_PATH:-}" != "$FLEET_MONITOR_LOCK_FILE" ] ||
  [ ! -e "/dev/fd/$lock_fd" ]; then
  echo "fleet-monitor: invalid lock handoff" >&2
  exit 2
fi
unset _FLEET_MONITOR_LOCK_FD _FLEET_MONITOR_LOCK_PATH

if ! touch "$FLEET_SWEPT" "$FLEET_PENDING" "$FLEET_DELIVERY_FAILURES" \
  "$FLEET_LOG" 2>/dev/null; then
  echo "fleet-monitor: runtime state is not writable" >&2
  exit 2
fi

prev=""
prev_seed=""
coord_seq_seen=""
coord_seq_time=0
coord_spinner_seen=0
blocked_reported=" "
fault_state_reported=0

report_fault_state_failure() {
  [ "$fault_state_reported" -eq 1 ] && return 0
  fault_state_reported=1
  printf 'WAKE state failures\n'
}

log() {
  if printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" \
    2>/dev/null >> "$FLEET_LOG"; then
    clear_fault state:log || true
  else
    report_once state:log "WAKE state log"
  fi
}

fault_seen() {
  grep -Fqx -- "$1" "$FLEET_DELIVERY_FAILURES" 2>/dev/null
}

record_fault() {
  local status
  fault_seen "$1"
  status=$?
  case "$status" in
    0) return 1 ;;
    1) ;;
    *) report_fault_state_failure; return 1 ;;
  esac
  if ! printf '%s\n' "$1" 2>/dev/null >> "$FLEET_DELIVERY_FAILURES"; then
    report_fault_state_failure
    return 1
  fi
}

clear_fault() {
  local key="$1" tmp status
  fault_seen "$key"
  status=$?
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) report_fault_state_failure; return 1 ;;
  esac
  tmp="$FLEET_DELIVERY_FAILURES.tmp.$$"
  if awk -v key="$key" '$0 != key' "$FLEET_DELIVERY_FAILURES" \
    2>/dev/null > "$tmp" &&
    mv "$tmp" "$FLEET_DELIVERY_FAILURES" 2>/dev/null; then
    fault_state_reported=0
    return 0
  fi
  unlink "$tmp" 2>/dev/null || true
  report_fault_state_failure
  return 1
}

rearm_fault_state() {
  local tmp
  [ "$fault_state_reported" -eq 1 ] || return 0
  tmp="$FLEET_DELIVERY_FAILURES.probe.$$"
  if awk '{ print }' "$FLEET_DELIVERY_FAILURES" 2>/dev/null > "$tmp" &&
    mv "$tmp" "$FLEET_DELIVERY_FAILURES" 2>/dev/null; then
    fault_state_reported=0
    return 0
  fi
  unlink "$tmp" 2>/dev/null || true
  return 1
}

report_once() {
  local key="$1" status
  shift
  record_fault "$key"
  status=$?
  [ "$status" -eq 1 ] || printf '%s\n' "$*"
}

# One line per agent: name|status|state_change_seq|spinner, sorted so the
# string can be diffed against the previous poll.
snapshot() {
  herdr agent list --session "$FLEET_SESSION" 2>&1 | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    rows = []
    for agent in data['result']['agents']:
        name = agent.get('name') or '?'
        status = agent['agent_status']
        seq = int(agent.get('state_change_seq', 0))
        title = agent.get('terminal_title') or ''
        spinner = 1 if any('\u2800' <= ch <= '\u28ff' for ch in title) else 0
        rows.append(f'{name}|{status}|{seq}|{spinner}')
    print(';'.join(sorted(rows)) or 'EMPTY')
except Exception as exc:
    print(f'PARSE-ERROR:{exc}')"
}

# Validate the shared shape and the identities whose uniqueness the monitor
# relies on once per poll. Only this whole-config check clears the config
# alarm; helper-local success must not mask another helper's semantic failure.
fleet_config_valid() {
  python3 - "$FLEET_CONFIG" 2>/dev/null <<'PYTHON'
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        config = json.load(fh)
    if not isinstance(config, dict):
        raise TypeError("config is not an object")
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    event_ids = set()
    agent_names = set()
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        events = stream.get("events", [])
        agents = stream.get("agents", {})
        if not isinstance(events, list) or not isinstance(agents, dict):
            raise TypeError("events or agents has the wrong shape")
        for event in events:
            if not isinstance(event, dict):
                raise TypeError("event is not an object")
            event_id = event.get("eventId")
            if event_id:
                if not isinstance(event_id, str) or event_id in event_ids:
                    raise TypeError("event ID is invalid or duplicated")
                event_ids.add(event_id)
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
            name = record.get("name")
            if name:
                if not isinstance(name, str) or name in agent_names:
                    raise TypeError("agent name is invalid or duplicated")
                agent_names.add(name)
except Exception:
    raise SystemExit(1)
PYTHON
}

swept_has_event() {
  grep -Fqx -- "$1" "$FLEET_SWEPT" 2>/dev/null
}

mark_swept() {
  local id="$1"
  swept_has_event "$id" && return 0
  printf '%s\n' "$id" 2>/dev/null >> "$FLEET_SWEPT"
}

pending_has_event() {
  awk -F '\t' -v id="$1" '
      $1 == id { found++ }
      END { exit found == 1 ? 0 : found == 0 ? 1 : 2 }
    ' "$FLEET_PENDING" 2>/dev/null
}

pending_has_lane() {
  awk -F '\t' -v lane="$1" '
      $2 == lane { found++ }
      END { exit found == 1 ? 0 : found == 0 ? 1 : 2 }
    ' "$FLEET_PENDING" 2>/dev/null
}

pending_event_for_lane() {
  awk -F '\t' -v lane="$1" \
    '$2 == lane { value = $1; found++ }
     END {
       if (found == 1) { print value; exit 0 }
       exit found == 0 ? 1 : 2
     }' \
    "$FLEET_PENDING" 2>/dev/null
}

pending_target_for_event() {
  awk -F '\t' -v id="$1" \
    '$1 == id { value = $6; found++ }
     END {
       if (found == 1) { print value; exit 0 }
       exit found == 0 ? 1 : 2
     }' \
    "$FLEET_PENDING" 2>/dev/null
}

pending_row_for_event() {
  awk -F '\t' -v id="$1" \
    '$1 == id { value = $0; found++ }
     END {
       if (found == 1) { print value; exit 0 }
       exit found == 0 ? 1 : 2
     }' \
    "$FLEET_PENDING" 2>/dev/null
}

pending_queue_readable() {
  awk -F '\t' '
      $0 == "" { next }
      NF < 5 || $1 == "" || $2 == "" || seen_id[$1]++ || seen_lane[$2]++ {
        bad = 1
      }
      $4 !~ /^(0|[1-9][0-9]*)$/ || $5 !~ /^(0|[1-9][0-9]*)$/ { bad = 1 }
      END { exit bad ? 2 : 0 }
    ' "$FLEET_PENDING" >/dev/null 2>&1
}

lane_already_handled() {
  local lane="$1" status
  pending_has_lane "$lane"
  status=$?
  case "$status" in
    0) return 0 ;;
    1) lane_has_ack "$lane"; return $? ;;
    *) return 3 ;;
  esac
}

lane_has_ack() {
  python3 - "$FLEET_CONFIG" "$1" 2>/dev/null <<'PYTHON'
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        config = json.load(fh)
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    records = []
    closed_events = []
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        events = stream.get("events", [])
        agents = stream.get("agents", {})
        if not isinstance(events, list) or not isinstance(agents, dict):
            raise TypeError("events or agents has the wrong shape")
        for event in events:
            if not isinstance(event, dict):
                raise TypeError("event is not an object")
            if (
                event.get("eventId")
                and event.get("agent") == sys.argv[2]
                and (
                    event.get("closedAt")
                    or event.get("teardownResolvedAt")
                    or event.get("kind")
                    in {"resolved-lost-output", "resolved-invalid-output"}
                )
            ):
                closed_events.append((stream, event))
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
            if record.get("name") == sys.argv[2]:
                records.append((stream, record))
    if len(records) > 1:
        raise TypeError("ambiguous agent identity")
    if records:
        stream, record = records[0]
        if record.get("dispatchState") not in {"closed", "resolved"}:
            raise SystemExit(1)
        event_id = record.get("captureEventId")
        captured_at = record.get("capturedAt") or record.get("resolvedAt")
        matching = [
            event
            for event in stream.get("events", [])
            if event.get("eventId")
            and event.get("agent") == sys.argv[2]
            and event.get("kind")
            in {
                "review-ready",
                "verdict",
                "resolved-lost-output",
                "resolved-invalid-output",
            }
        ]
        if event_id:
            matching = [event for event in matching if event.get("eventId") == event_id]
        elif captured_at:
            matching = [event for event in matching if event.get("at") == captured_at]
        if len(matching) > 1:
            raise TypeError("ambiguous agent capture identity")
        raise SystemExit(0 if matching else 1)
    if closed_events:
        raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    raise SystemExit(2)
raise SystemExit(1)
PYTHON
}

lane_partial_capture_id() {
  python3 - "$FLEET_CONFIG" "$1" 2>/dev/null <<'PYTHON'
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        config = json.load(fh)
    matches = []
    for stream in config.get("streams", []):
        for record in stream.get("agents", {}).values():
            if record.get("name") == sys.argv[2]:
                matches.append(record)
    if len(matches) > 1:
        raise TypeError("ambiguous agent identity")
    if matches and matches[0].get("dispatchState") == "captured":
        event_id = matches[0].get("captureEventId")
        if event_id:
            print(event_id)
except Exception:
    raise SystemExit(2)
PYTHON
}

lane_record() {
  python3 - "$FLEET_CONFIG" "$1" 2>/dev/null <<'PYTHON'
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        config = json.load(fh)
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    lane = sys.argv[2]
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        agents = stream.get("agents", {})
        if not isinstance(agents, dict):
            raise TypeError("agents is not an object")
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
            if record.get("name") == lane:
                print(f"{record.get('role', '')}|{record.get('dispatchState', '')}")
                raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    raise SystemExit(2)
raise SystemExit(1)
PYTHON
}

lane_registered() {
  local record state
  record="$(lane_record "$1")"
  case "$?" in
    0)
      state="${record#*|}"
      case "$state" in
        reserved | tab-created | started) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

lane_is_verdict() {
  local record role
  if record="$(lane_record "$1")"; then
    role="${record%%|*}"
    case "$role" in
      review) return 0 ;;
      impl) return 1 ;;
    esac
  fi
  # Compatibility for older configs whose agent records omitted `role`.
  fleet_is_verdict_lane "$1"
}

# Rebuild the one bit of transition history that an in-memory diff cannot
# survive: a dispatched lane that is already absent when this monitor starts.
# Agent names are unique per dispatch, so `@missing` is a stable event ID.
missing_registered_lanes() {
  python3 - "$FLEET_CONFIG" "$1" 2>/dev/null <<'PYTHON'
import json
import sys

path, inventory = sys.argv[1:]
try:
    with open(path) as fh:
        config = json.load(fh)
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    live = {row.split("|", 1)[0] for row in inventory.split(";") if "|" in row}
    missing = []
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        events = stream.get("events", [])
        agents = stream.get("agents", {})
        if not isinstance(events, list) or not isinstance(agents, dict):
            raise TypeError("events or agents has the wrong shape")
        for event in events:
            if not isinstance(event, dict):
                raise TypeError("event is not an object")
        captured = {event.get("agent") for event in events if event.get("eventId")}
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
            name = record.get("name")
            state = record.get("dispatchState", "")
            # `prompting` is deliberately monitorable: it is persisted before
            # prompt delivery, closing the accepted-prompt/process-crash gap.
            # A legacy record without dispatchState is active unless an event
            # already proves its output was captured.
            monitorable = state in {"prompting", "active"} or (
                not state and name not in captured
            )
            if name and monitorable and name not in live:
                missing.append(name)
except Exception:
    print("!CONFIG")
    raise SystemExit(0)

print("!OK")
for name in missing:
    print(name)
PYTHON
}

reconcile_missing_lanes() {
  local cur="$1" lane pending_id target status
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    if [ "$lane" = "!CONFIG" ]; then
      report_once config:unreadable "WAKE state fleet.json"
      continue
    fi
    if [ "$lane" = "!OK" ]; then
      continue
    fi
    pending_id="$(pending_event_for_lane "$lane")"
    status=$?
    case "$status" in
      0)
        target="$(pending_target_for_event "$pending_id")"
        status=$?
        if [ "$status" -ne 0 ]; then
          report_once state:pending "WAKE state pending"
          continue
        fi
        [ "$target" = vanished ] || promote_vanished "$pending_id"
        continue
        ;;
      1) ;;
      *)
        report_once state:pending "WAKE state pending"
        continue
        ;;
    esac
    lane_already_handled "$lane"
    status=$?
    case "$status" in
      0) continue ;;
      2)
        report_once config:unreadable "WAKE state fleet.json"
        continue
        ;;
      3)
        report_once state:pending "WAKE state pending"
        continue
        ;;
    esac
    queue_event "$lane@missing" "$lane" vanished vanished
  done < <(missing_registered_lanes "$cur")
}

unclosed_captures() {
  python3 - "$FLEET_CONFIG" "$FLEET_TEARDOWN_GRACE_SECONDS" 2>/dev/null <<'PYTHON'
from datetime import datetime
import json
import sys
import time


def stale_capture(value, grace_seconds):
    if not isinstance(value, str) or not value.strip():
        return True
    try:
        normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
        captured_at = datetime.fromisoformat(normalized)
        if captured_at.tzinfo is None:
            return True
        age = time.time() - captured_at.timestamp()
        return age < 0 or age >= grace_seconds
    except (OverflowError, TypeError, ValueError):
        return True

try:
    with open(sys.argv[1]) as fh:
        config = json.load(fh)
    grace_seconds = int(sys.argv[2])
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    records = []
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        events = stream.get("events", [])
        agents = stream.get("agents", {})
        if not isinstance(events, list) or not isinstance(agents, dict):
            raise TypeError("events or agents has the wrong shape")
        for event in events:
            if not isinstance(event, dict):
                raise TypeError("event is not an object")
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
            if record.get("dispatchState") == "captured" and record.get("name"):
                name = record["name"]
                event_id = record.get("captureEventId", "")
                matching_events = [
                    event
                    for event in events
                    if event.get("agent") == name
                    and (
                        (event_id and event.get("eventId") == event_id)
                        or (
                            not event_id
                            and record.get("capturedAt")
                            and event.get("at") == record.get("capturedAt")
                        )
                    )
                ]
                if not event_id and not matching_events:
                    agent_events = [event for event in events if event.get("agent") == name]
                    if len(agent_events) == 1:
                        matching_events = agent_events
                if len(matching_events) == 1 and (
                    matching_events[0].get("closedAt")
                    or matching_events[0].get("teardownResolvedAt")
                    or matching_events[0].get("kind")
                    in {"resolved-lost-output", "resolved-invalid-output"}
                ):
                    continue
                if not stale_capture(record.get("capturedAt"), grace_seconds):
                    continue
                if not event_id:
                    candidates = [
                        event.get("eventId", "")
                        for event in events
                        if event.get("agent") == name
                        and event.get("eventId")
                        and not event.get("closedAt")
                        and not event.get("teardownResolvedAt")
                        and event.get("kind")
                        not in {"resolved-lost-output", "resolved-invalid-output"}
                    ]
                    event_id = candidates[0] if len(candidates) == 1 else f"{name}@captured"
                records.append((name, event_id))
except Exception:
    print("!CONFIG")
    raise SystemExit(0)

print("!OK")
for name, event_id in records:
    print(f"{name}\t{event_id}")
PYTHON
}

# Return zero when an exact captured event is past grace, one while a current
# captured record is still inside grace, and two for unreadable config. An
# absent or replaced current record is immediately actionable: its normal
# close path no longer exists.
capture_teardown_due() {
  python3 - "$FLEET_CONFIG" "$1" "$2" "$FLEET_TEARDOWN_GRACE_SECONDS" \
    2>/dev/null <<'PYTHON'
from datetime import datetime
import json
import sys
import time


def is_stale(value, grace_seconds):
    if not isinstance(value, str) or not value.strip():
        return True
    try:
        normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
        captured_at = datetime.fromisoformat(normalized)
        if captured_at.tzinfo is None:
            return True
        age = time.time() - captured_at.timestamp()
        return age < 0 or age >= grace_seconds
    except (OverflowError, TypeError, ValueError):
        return True


path, event_id, lane, grace = sys.argv[1:]
try:
    with open(path) as fh:
        config = json.load(fh)
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    matches = []
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        events = stream.get("events", [])
        agents = stream.get("agents", {})
        if not isinstance(events, list) or not isinstance(agents, dict):
            raise TypeError("events or agents has the wrong shape")
        for event in events:
            if not isinstance(event, dict):
                raise TypeError("event is not an object")
            if event.get("eventId") == event_id:
                matches.append((stream, event))
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
    if len(matches) != 1:
        raise TypeError("event identity is missing or ambiguous")
    stream, event = matches[0]
    if event.get("agent") != lane:
        raise TypeError("event identity belongs to another agent")
    if (
        event.get("closedAt")
        or event.get("teardownResolvedAt")
        or event.get("kind")
        in {"resolved-lost-output", "resolved-invalid-output"}
    ):
        raise SystemExit(1)
    records = [
        record
        for record in stream.get("agents", {}).values()
        if record.get("name") == lane
    ]
    if len(records) == 1 and records[0].get("dispatchState") == "captured":
        raise SystemExit(0 if is_stale(records[0].get("capturedAt"), int(grace)) else 1)
    raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    raise SystemExit(2)
PYTHON
}

reconcile_unclosed_captures() {
  local lane event_id key stale_lane teardown_rows config_ok=0 is_stale status
  local -a stale_lanes=() teardown_faults=()
  while IFS=$'\t' read -r lane event_id; do
    case "$lane" in
      '') ;;
      '!CONFIG') report_once config:unreadable "WAKE state fleet.json" ;;
      '!OK') config_ok=1 ;;
      *)
        stale_lanes+=("$lane")
        pending_has_lane "$lane"
        status=$?
        case "$status" in
          0) ;;
          1) queue_event "$event_id" "$lane" captured teardown ;;
          *) report_once state:pending "WAKE state pending" ;;
        esac
        ;;
    esac
  done < <(unclosed_captures)

  # A stale capture can exist without a pending settlement. Rearm its alarm
  # when teardown completes or a corrected timestamp returns it to grace.
  [ "$config_ok" -eq 1 ] || return 0
  if ! teardown_rows="$(awk '/^teardown:/' "$FLEET_DELIVERY_FAILURES" 2>/dev/null)"; then
    report_fault_state_failure
    return 0
  fi
  while IFS= read -r key; do
    case "$key" in teardown:*) teardown_faults+=("$key") ;; esac
  done <<< "$teardown_rows"
  for key in "${teardown_faults[@]+"${teardown_faults[@]}"}"; do
    lane="${key#teardown:}"
    is_stale=0
    for stale_lane in "${stale_lanes[@]+"${stale_lanes[@]}"}"; do
      if [ "$lane" = "$stale_lane" ]; then
        is_stale=1
        break
      fi
    done
    [ "$is_stale" -eq 1 ] || clear_fault "$key" || true
  done
}


# Persist before notification. Fields are: event-id, lane, observed-state,
# last-send-epoch, send-count, delivery target.
queue_event() {
  local id="$1" lane="$2" state="$3" target="$4" status
  pending_has_event "$id"
  status=$?
  case "$status" in
    0)
      [ "$target" = vanished ] || return 0
      promote_vanished "$id"
      return
      ;;
    1) ;;
    *)
      report_once state:pending "WAKE state pending"
      return 1
      ;;
  esac
  if ! printf '%s\t%s\t%s\t0\t0\t%s\n' "$id" "$lane" "$state" "$target" \
    2>/dev/null >> "$FLEET_PENDING"; then
    report_once "queue:$id" "WAKE state $id"
    return 1
  fi
  clear_fault "queue:$id"
  log "queued $id ($state)"
}

promote_vanished() {
  local id="$1" tmp
  tmp="$FLEET_PENDING.tmp.$$"
  if awk -F '\t' -v OFS='\t' -v id="$id" '
      $1 == id {
        found++
        $3 = "vanished"
        $4 = 0
        $6 = "vanished"
      }
      { print }
      END { exit found == 1 ? 0 : 2 }
    ' "$FLEET_PENDING" 2>/dev/null > "$tmp" &&
    mv "$tmp" "$FLEET_PENDING" 2>/dev/null; then
    log "promoted $id to vanished"
    return 0
  fi
  unlink "$tmp" 2>/dev/null || true
  report_once state:pending "WAKE state pending"
  return 1
}

# A delivery is acknowledged by the durable state mutation made by
# `fleet capture` or `fleet resolve-event`: an exact event ID and agent match.
# This is stronger than `herdr agent prompt` returning zero, which proves only
# that transport accepted the prompt.
event_acked() {
  python3 - "$FLEET_CONFIG" "$1" "$2" 2>/dev/null <<'PYTHON'
import json
import sys

path, event_id, lane = sys.argv[1:]
try:
    with open(path) as fh:
        config = json.load(fh)
    streams = config.get("streams", [])
    if not isinstance(streams, list):
        raise TypeError("streams is not a list")
    matches = []
    for stream in streams:
        if not isinstance(stream, dict):
            raise TypeError("stream is not an object")
        events = stream.get("events", [])
        agents = stream.get("agents", {})
        if not isinstance(events, list) or not isinstance(agents, dict):
            raise TypeError("events or agents has the wrong shape")
        matching_records = []
        for event in events:
            if not isinstance(event, dict):
                raise TypeError("event is not an object")
            if event.get("eventId") == event_id:
                matches.append((stream, event))
        for record in agents.values():
            if not isinstance(record, dict):
                raise TypeError("agent record is not an object")
            if record.get("name") == lane:
                matching_records.append(record)
        if len(matching_records) > 1:
            raise TypeError("ambiguous agent identity")
    if len(matches) > 1:
        raise TypeError("ambiguous event identity")
    if not matches:
        raise SystemExit(1)
    stream, event = matches[0]
    if event.get("agent") != lane:
        raise TypeError("event identity belongs to another agent")
    if (
        event.get("closedAt")
        or event.get("teardownResolvedAt")
        or event.get("kind")
        in {"resolved-lost-output", "resolved-invalid-output"}
    ):
        raise SystemExit(0)
    records = [
        record
        for record in stream.get("agents", {}).values()
        if record.get("name") == lane
    ]
    if len(records) > 1:
        raise TypeError("ambiguous agent identity")
    if records and records[0].get("dispatchState") in {"closed", "resolved"}:
        record = records[0]
        capture_event_id = record.get("captureEventId")
        captured_at = record.get("capturedAt") or record.get("resolvedAt")
        if capture_event_id == event_id or (
            not capture_event_id and captured_at and captured_at == event.get("at")
        ):
            raise SystemExit(0)
        if not capture_event_id and not captured_at:
            agent_events = [
                candidate
                for candidate in stream.get("events", [])
                if candidate.get("eventId")
                and candidate.get("agent") == lane
                and candidate.get("kind")
                in {
                    "review-ready",
                    "verdict",
                    "resolved-lost-output",
                    "resolved-invalid-output",
                }
            ]
            if len(agent_events) == 1 and agent_events[0] is event:
                raise SystemExit(0)
    raise SystemExit(3)
except SystemExit:
    raise
except Exception:
    raise SystemExit(2)
raise SystemExit(1)
PYTHON
}

mark_pending_sent() {
  local ids="$1" now="$2" tmp
  tmp="$FLEET_PENDING.tmp.$$"
  if awk -F '\t' -v OFS='\t' -v ids="$ids" -v now="$now" '
      BEGIN { count = split(ids, values, ","); for (i = 1; i <= count; i++) due[values[i]] = 1 }
      $1 in due {
        seen[$1]++
        $4 = now
        $5 = ($5 + 0) + 1
      }
      { print }
      END {
        for (i = 1; i <= count; i++) {
          if (seen[values[i]] != 1) exit 2
        }
      }
    ' "$FLEET_PENDING" 2>/dev/null > "$tmp" &&
    mv "$tmp" "$FLEET_PENDING" 2>/dev/null; then
    return 0
  fi
  unlink "$tmp" 2>/dev/null || true
  return 1
}

retry_delay_seconds() {
  local attempts="$1" factor=1 step
  # Exponential retry limits duplicate model turns while preserving eventual
  # delivery. Cap at eight acknowledgement windows.
  step=$((attempts - 1))
  [ "$step" -lt 0 ] && step=0
  [ "$step" -gt 3 ] && step=3
  while [ "$step" -gt 0 ]; do
    factor=$((factor * 2))
    step=$((step - 1))
  done
  printf '%s\n' $((FLEET_ACK_TIMEOUT_SECONDS * factor))
}

report_new_event_faults() {
  local kind="$1" label="$2"
  shift 2
  local id new=""
  for id in "$@"; do
    record_fault "$kind:$id"
    case "$?" in
      0 | 2)
        new="$new $id"
        ;;
    esac
  done
  [ -z "$new" ] || printf 'WAKE %s%s\n' "$label" "$new"
}

deliver_pending() {
  local now="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  local -a ids=("$@") specs=()
  local id row lane state status csv="" joined="" old_ifs="$IFS" delivered=0
  local delivery_output detail=""

  for id in "${ids[@]}"; do
    row="$(pending_row_for_event "$id")"
    status=$?
    if [ "$status" -ne 0 ]; then
      report_once state:pending "WAKE state pending"
      return 0
    fi
    IFS=$'\t' read -r _ lane state _ _ <<< "$row"
    specs+=("$id=$state")
    csv="${csv:+$csv,}$id"
  done
  IFS=,
  joined="${specs[*]}"
  IFS="$old_ifs"

  # Persist before crossing the prompt side-effect boundary. If the monitor
  # dies after Herdr accepts the prompt, restart waits for the ACK deadline
  # instead of immediately spending a duplicate model turn. A crash between
  # this write and submission delays, but cannot lose, the eventual retry.
  if ! mark_pending_sent "$csv" "$now"; then
    report_new_event_faults state state "${ids[@]}"
    return 0
  fi
  for id in "${ids[@]}"; do
    clear_fault "state:$id"
  done

  delivery_output="$FLEET_STATE_DIR/.fleet-delivery.$$"
  if { herdr agent prompt "$FLEET_COORDINATOR" --session "$FLEET_SESSION" \
    "SETTLED $joined. $FLEET_SWEEP_INSTRUCTION" \
    > "$delivery_output" 2>&1; } 2>/dev/null; then
    delivered=1
  fi
  if [ -s "$delivery_output" ]; then
    detail="$(tr '\n\t' '  ' 2>/dev/null < "$delivery_output" | cut -c1-240)"
  fi
  unlink "$delivery_output" 2>/dev/null || true

  # Herdr prompt errors can be advisory: the turn may have been accepted even
  # when its status wait failed. Wait for either the exact capture ACK or the
  # retry deadline instead of spending a new model turn on every ten-second
  # poll.
  if [ "$delivered" -eq 1 ]; then
    for id in "${ids[@]}"; do
      clear_fault "delivery:$id"
    done
    log "delivered ${#ids[@]} event(s) to coordinator: $csv"
  else
    report_new_event_faults delivery delivery "${ids[@]}"
    log "delivery failed: $csv${detail:+ ($detail)}"
  fi
}

# Verdict and teardown events stay in the same durable queue, but their
# delivery target is the orchestrator's persistent-monitor stdout. They repeat
# only after the acknowledgement timeout, so a lost wake heals without
# poll-by-poll noise.
deliver_wakes() {
  local now="$1" label="$2"
  shift 2
  [ "$#" -gt 0 ] || return 0
  local -a ids=("$@")
  local csv="" id
  for id in "${ids[@]}"; do
    csv="${csv:+$csv,}$id"
  done
  if ! mark_pending_sent "$csv" "$now"; then
    report_new_event_faults state state "${ids[@]}"
    return 0
  fi
  for id in "${ids[@]}"; do
    clear_fault "state:$id"
  done
  printf 'WAKE %s %s\n' "$label" "${ids[*]}"
}

# Reconcile every pending event on every poll. This makes delivery at-least-
# once and idempotent: a failed notification, monitor restart, or missed
# working->done sample cannot lose the settlement.
reconcile_pending() {
  if ! pending_queue_readable; then
    report_once state:pending "WAKE state pending"
    return 0
  fi
  [ -s "$FLEET_PENDING" ] || return 0

  local cur="$1" now tmp source id lane state sent attempts target ack_status
  local config_bad=0 pending_write_failed=0
  local retry_delay
  local coordinator_state
  local -a due_coordinator=() due_verdict=() due_teardown=()
  local -a due_vanished=() late=() acked=()
  now="$(date +%s)"
  coordinator_state="$(printf '%s\n' "$cur" | tr ';' '\n' |
    awk -F'|' -v c="$FLEET_COORDINATOR" '$1 == c { print $2 }')"
  tmp="$FLEET_PENDING.tmp.$$"
  source="$FLEET_PENDING.read.$$"
  if ! cp "$FLEET_PENDING" "$source" 2>/dev/null; then
    report_once state:pending "WAKE state pending"
    return 0
  fi
  if ! awk -F '\t' '
      $0 == "" { next }
      $4 !~ /^(0|[1-9][0-9]*)$/ || $5 !~ /^(0|[1-9][0-9]*)$/ { exit 1 }
    ' "$source" 2>/dev/null; then
    unlink "$source" 2>/dev/null || true
    report_once state:pending "WAKE state pending"
    return 0
  fi
  : 2>/dev/null > "$tmp" || {
    unlink "$source" 2>/dev/null || true
    report_once state:pending "WAKE state pending"
    return 0
  }

  while IFS=$'\t' read -r id lane state sent attempts target || [ -n "${id:-}" ]; do
    [ -n "${id:-}" ] || continue
    case "${sent:-}" in '' | *[!0-9]*) sent=0 ;; esac
    case "${attempts:-}" in '' | *[!0-9]*) attempts=0 ;; esac
    if [ -z "${target:-}" ]; then
      if lane_is_verdict "$lane"; then
        target=verdict
      else
        target=coordinator
      fi
    fi
    event_acked "$id" "$lane"
    ack_status=$?
    if [ "$ack_status" -eq 0 ]; then
      if mark_swept "$id"; then
        acked+=("$id")
        clear_fault "delivery:$id"
        clear_fault "unacked:$id"
        clear_fault "state:$id"
        clear_fault "teardown:$lane"
        log "acknowledged and swept $id"
        continue
      fi
      report_once "ledger:$id" "WAKE state $id"
      if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$lane" "$state" \
        "$sent" "$attempts" "$target" 2>/dev/null >> "$tmp"; then
        pending_write_failed=1
        break
      fi
      # The durable ACK exists; only the local ledger write needs retrying.
      # Never redeliver a model turn for this state-file failure.
      continue
    elif [ "$ack_status" -eq 2 ]; then
      config_bad=1
      report_once config:unreadable "WAKE state fleet.json"
    elif [ "$ack_status" -eq 3 ]; then
      # The event is already captured, so redelivery can only spend a
      # duplicate model turn. Once its grace expires, move it to a dedicated
      # durable teardown target whose terse wakes follow the normal backoff.
      capture_teardown_due "$id" "$lane"
      case "$?" in
        0)
          if [ "$target" != teardown ]; then
            target=teardown
            sent=0
            attempts=0
          fi
          retry_delay="$(retry_delay_seconds "$attempts")"
          if [ "$sent" -eq 0 ] || [ $((now - sent)) -ge "$retry_delay" ]; then
            due_teardown+=("$id")
          fi
          ;;
        2)
          config_bad=1
          report_once config:unreadable "WAKE state fleet.json"
          ;;
      esac
      if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$lane" "$state" \
        "$sent" "$attempts" "$target" 2>/dev/null >> "$tmp"; then
        pending_write_failed=1
        break
      fi
      continue
    fi

    if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$lane" "$state" \
      "${sent:-0}" "${attempts:-0}" "$target" 2>/dev/null >> "$tmp"; then
      pending_write_failed=1
      break
    fi
    retry_delay="$(retry_delay_seconds "$attempts")"
    if [ "$sent" -eq 0 ] || [ $((now - sent)) -ge "$retry_delay" ]; then
      case "$target" in
        verdict) due_verdict+=("$id") ;;
        teardown) due_teardown+=("$id") ;;
        vanished) due_vanished+=("$id") ;;
        *)
          # A first delivery may be queued behind a busy coordinator. Avoid
          # adding repeated turns while it is still working, but do not hide
          # an overdue acknowledgement from the orchestrator.
          if [ "$sent" -eq 0 ] || [ "$coordinator_state" != working ]; then
            due_coordinator+=("$id")
          fi
          ;;
      esac
      if [ "$target" = coordinator ] && [ "$sent" -ne 0 ]; then
        late+=("$id")
      fi
    fi
  done < "$source"

  unlink "$source" 2>/dev/null || true
  if [ "$pending_write_failed" -ne 0 ]; then
    unlink "$tmp" 2>/dev/null || true
    report_once state:pending "WAKE state pending"
    return 0
  fi

  if ! mv "$tmp" "$FLEET_PENDING" 2>/dev/null; then
    unlink "$tmp" 2>/dev/null || true
    report_once state:pending "WAKE state pending"
    return 0
  fi
  clear_fault state:pending
  if [ "$config_bad" -ne 0 ]; then
    # With unreadable durable state, an ACK may already exist. Do not spend a
    # duplicate model turn until the monitor can prove that it does not.
    return 0
  fi
  for id in "${acked[@]+"${acked[@]}"}"; do
    clear_fault "ledger:$id"
  done
  if [ -n "${late[*]-}" ]; then
    report_new_event_faults unacked unacked "${late[@]+"${late[@]}"}"
  fi
  deliver_pending "$now" "${due_coordinator[@]+"${due_coordinator[@]}"}"
  deliver_wakes "$now" verdict "${due_verdict[@]+"${due_verdict[@]}"}"
  deliver_wakes "$now" teardown "${due_teardown[@]+"${due_teardown[@]}"}"
  deliver_wakes "$now" vanished "${due_vanished[@]+"${due_vanished[@]}"}"
}

settle() {
  local lane="$1" state="$2" seq="$3" id="$1@$3" handled registered partial_id
  lane_already_handled "$lane"
  handled=$?
  case "$handled" in
    0) return 0 ;;
    2)
      report_once config:unreadable "WAKE state fleet.json"
      return 0
      ;;
    3)
      report_once state:pending "WAKE state pending"
      return 0
      ;;
  esac
  lane_registered "$lane"
  registered=$?
  if [ "$registered" -eq 1 ]; then
    log "ignored unregistered settled lane $lane"
    return 0
  fi
  if [ "$registered" -eq 2 ]; then
    report_once config:unreadable "WAKE state fleet.json"
    return 0
  fi
  partial_id="$(lane_partial_capture_id "$lane")"
  case "$?" in
    0) [ -z "$partial_id" ] || id="$partial_id" ;;
    *) report_once config:unreadable "WAKE state fleet.json"; return 0 ;;
  esac
  if lane_is_verdict "$lane"; then
    queue_event "$id" "$lane" "$state" verdict
  else
    queue_event "$id" "$lane" "$state" coordinator
  fi
}

# Lanes that settled while no monitor was armed still need handling.
baseline() {
  local name state seq spinner
  while IFS='|' read -r name state seq spinner; do
    [ "$name" = "$FLEET_COORDINATOR" ] && continue
    case "$state" in
      done | idle)
        settle "$name" "$state" "$seq"
        ;;
    esac
  done < <(printf '%s\n' "$1" | tr ';' '\n')
}

transitions() {
  FLEET_COORDINATOR="$FLEET_COORDINATOR" python3 - "$1" "$2" 2>/dev/null <<'PYTHON'
import os
import sys


def parse(text):
    table = {}
    for row in text.split(';'):
        parts = row.split('|')
        if len(parts) == 4:
            table[parts[0]] = (parts[1], int(parts[2]), int(parts[3]))
    return table


old, new = parse(sys.argv[1]), parse(sys.argv[2])
coordinator = os.environ['FLEET_COORDINATOR']
settled = {'done', 'idle'}

for lane, (state, seq, _spinner) in new.items():
    was = old.get(lane)
    if lane == coordinator:
        if was and was[0] == 'blocked' and state == 'blocked':
            print(f'BLOCKED:{lane}')
        continue
    if state in settled and (not was or was[0] not in settled):
        print(f'SETTLED:{lane} {state} {seq}')
    # Two consecutive blocked polls, not one: a single blocked reading is
    # usually a lane between turns, sustained blocked is a dialog waiting.
    if was and was[0] == 'blocked' and state == 'blocked':
        print(f'BLOCKED:{lane}')
    if not was and state not in settled:
        print(f'INFO:new lane {lane} ({state})')

for lane, (state, seq, _spinner) in old.items():
    if lane == coordinator:
        continue
    if lane not in new and state in ('working', 'done', 'idle'):
        print(f'VANISHED:{lane}@{seq}')
PYTHON
}

# A stall needs BOTH liveness signals dead across the whole window:
# state_change_seq frozen AND no spinner sighting in any poll of that window.
coordinator_oversight() {
  local cur="$1" state seq spinner now frozen_for
  # EMPTY already emits WAKE inventory; a second coordinator-missing wake
  # would add no recovery information.
  [ "$cur" = EMPTY ] && return 0
  state="$(printf '%s\n' "$cur" | tr ';' '\n' | awk -F'|' -v c="$FLEET_COORDINATOR" '$1 == c { print $2 }')"
  seq="$(printf '%s\n' "$cur" | tr ';' '\n' | awk -F'|' -v c="$FLEET_COORDINATOR" '$1 == c { print $3 }')"
  spinner="$(printf '%s\n' "$cur" | tr ';' '\n' | awk -F'|' -v c="$FLEET_COORDINATOR" '$1 == c { print $4 }')"
  now="$(date +%s)"
  if [ -z "$state" ]; then
    report_once coordinator:missing "WAKE coordinator missing"
    return 0
  fi
  clear_fault coordinator:missing

  if [ "$state" != working ]; then
    coord_seq_seen="$seq"
    coord_seq_time="$now"
    coord_spinner_seen=0
    return 0
  fi
  if [ "$coord_seq_seen" != "$seq" ]; then
    coord_seq_seen="$seq"
    coord_seq_time="$now"
    coord_spinner_seen=0
    return 0
  fi

  [ "$spinner" = 1 ] && coord_spinner_seen=$((coord_spinner_seen + 1))
  frozen_for=$((now - coord_seq_time))
  [ "$frozen_for" -ge "$FLEET_STALL_SECONDS" ] || return 0
  if [ "$coord_spinner_seen" = 0 ]; then
    printf 'WAKE coordinator-stall %s\n' "$frozen_for"
  else
    log "coordinator long turn: seq $seq frozen ${frozen_for}s; $coord_spinner_seen spinner sightings"
  fi
  coord_seq_time="$now"
  coord_spinner_seen=0
}

poll() {
  local cur seed_tip line kind rest lane state seq pending_id heartbeat_tmp
  rearm_fault_state || true
  cur="$(snapshot)"
  if seed_tip="$(git -C "$FLEET_SEED" rev-parse --short HEAD 2>/dev/null)"; then
    clear_fault state:seed
  else
    report_once state:seed "WAKE state seed"
    seed_tip="$prev_seed"
  fi

  case "$cur" in
    PARSE-ERROR*)
      report_once inventory "WAKE inventory"
      return 0
      ;;
    EMPTY)
      # A valid empty inventory is readable but still exceptional. Continue
      # so config-owned active lanes become durable `@missing` events.
      report_once inventory "WAKE inventory"
      ;;
    *) clear_fault inventory ;;
  esac
  heartbeat_tmp="$FLEET_HEARTBEAT.tmp.$$"
  if ! date +%s 2>/dev/null > "$heartbeat_tmp" ||
    ! mv "$heartbeat_tmp" "$FLEET_HEARTBEAT" 2>/dev/null; then
    unlink "$heartbeat_tmp" 2>/dev/null || true
    report_once state:heartbeat "WAKE state heartbeat"
  else
    clear_fault state:heartbeat
  fi

  if fleet_config_valid; then
    clear_fault config:unreadable || true
  else
    report_once config:unreadable "WAKE state fleet.json"
    return 0
  fi
  if pending_queue_readable; then
    clear_fault state:pending || true
  else
    # Never let a write-only or structurally ambiguous queue look empty: a
    # producer could append duplicates that would become multiple model turns
    # when read access returns.
    report_once state:pending "WAKE state pending"
    return 0
  fi

  if [ -z "$prev" ]; then
    baseline "$cur"
    reconcile_missing_lanes "$cur"
    reconcile_unclosed_captures
    reconcile_pending "$cur"
    coordinator_oversight "$cur"
    prev="$cur"
    [ -z "$seed_tip" ] || prev_seed="$seed_tip"
    return 0
  fi

  if [ -n "$prev_seed" ] && [ "$seed_tip" != "$prev_seed" ]; then
    printf 'WAKE seed %s %s\n' "$prev_seed" "$seed_tip"
  fi

  # Process acknowledgements before disappearance detection. The coordinator
  # is allowed to capture and close a settled lane between polls; once its
  # event is durable, that disappearance is normal rather than VANISHED.
  reconcile_pending "$cur"

  while read -r line; do
    [ -n "$line" ] || continue
    kind="${line%%:*}"
    rest="${line#*:}"
    case "$kind" in
      SETTLED)
        lane="${rest%% *}"
        rest="${rest#* }"
        state="${rest%% *}"
        seq="${rest##* }"
        settle "$lane" "$state" "$seq"
        ;;
      VANISHED)
        lane="${rest%@*}"
        pending_id="$(pending_event_for_lane "$lane")"
        case "$?" in
          0) promote_vanished "$pending_id" ;;
          1)
            lane_already_handled "$lane"
            case "$?" in
              0) ;;
              2) report_once config:unreadable "WAKE state fleet.json" ;;
              3) report_once state:pending "WAKE state pending" ;;
              *)
                event_acked "$rest" "$lane"
                case "$?" in
                  0) mark_swept "$rest" || report_once "ledger:$rest" "WAKE state $rest" ;;
                  2) report_once config:unreadable "WAKE state fleet.json" ;;
                  *)
                    if lane_registered "$lane"; then
                      queue_event "$rest" "$lane" vanished vanished
                    else
                      log "ignored vanished unregistered lane $lane"
                    fi
                    ;;
                esac
                ;;
            esac
            ;;
          *) report_once state:pending "WAKE state pending" ;;
        esac
        ;;
      BLOCKED)
        lane="$rest"
        case "$blocked_reported" in
          *" $lane "*) log "blocked $lane (already reported)" ;;
          *)
            printf 'WAKE blocked %s\n' "$lane"
            blocked_reported="$blocked_reported$lane "
            ;;
        esac
        ;;
      INFO) log "$rest" ;;
    esac
  done < <(transitions "$prev" "$cur")

  # Reconcile every currently settled registered lane as well as explicit
  # transitions. This closes the startup race where an agent is first sampled
  # idle before its dispatch reservation becomes active, then finishes before
  # the following poll.
  baseline "$cur"
  reconcile_missing_lanes "$cur"
  reconcile_unclosed_captures

  # A lane that left blocked can raise the alarm again next time.
  for lane in $blocked_reported; do
    case ";$cur" in
      *";$lane|blocked|"*) ;;
      *) blocked_reported="${blocked_reported// $lane / }" ;;
    esac
  done

  # Deliver settlements first observed in this poll.
  reconcile_pending "$cur"
  coordinator_oversight "$cur"
  prev="$cur"
  [ -z "$seed_tip" ] || prev_seed="$seed_tip"
}

trap 'exit 143' TERM
trap 'exit 130' INT

while true; do
  poll
  [ "$once" = 1 ] && exit 0
  sleep "$FLEET_POLL_SECONDS"
done
