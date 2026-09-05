#!/usr/bin/env bats
# cspell:ignore acked noncanonical nonrecursive prestamped unacked
# shellcheck disable=SC2016,SC2030,SC2031

load helper
bats_require_minimum_version 1.5.0

setup() {
  setup_sandbox

  MONITOR="$REPO_ROOT/skills/workflow/fleet-orchestrator/scripts/fleet-monitor.sh"
  ENV_SCRIPT="$REPO_ROOT/skills/workflow/fleet-orchestrator/scripts/fleet-env.sh"
  SEED="$SANDBOX/seed"
  STATE_DIR="$SEED/temp/fleet"
  FLEET_FILE="$STATE_DIR/fleet.json"
  PENDING_FILE="$STATE_DIR/fleet-monitor.pending"
  SWEPT_FILE="$STATE_DIR/fleet-monitor.swept"
  LOG_FILE="$STATE_DIR/fleet-monitor.log"
  LOCK_FILE="$STATE_DIR/fleet-monitor.lockfile"
  HERDR_INVENTORY="$SANDBOX/herdr-inventory.json"
  HERDR_CALLS="$SANDBOX/herdr-calls.log"
  FAKE_BIN="$SANDBOX/bin"
  REAL_GIT="$(command -v git)"
  REAL_MV="$(command -v mv)"
  REAL_PYTHON="$(command -v python3)"

  mkdir -p "$SEED" "$STATE_DIR" "$FAKE_BIN"
  git -C "$SEED" init -q
  printf '/temp/\n' > "$SEED/.gitignore"
  git -C "$SEED" add .gitignore
  git -C "$SEED" \
    -c user.name='Fleet Monitor Test' \
    -c user.email='fleet-monitor@example.test' \
    commit -qm 'Ignore fleet runtime state'

  write_fake_herdr
  : > "$HERDR_CALLS"
  export HERDR_LIST_MODE=ok
  export HERDR_PROMPT_RC=0
  export HERDR_PROMPT_OUTPUT=''
  export HERDR_REQUIRE_PRESTAMP=0
  export GIT_REV_PARSE_FAIL=0
  export MV_FAIL_DEST=''
  export MV_EMPTY_AFTER_DEST=''
  export PYTHON_CLOSE_AFTER_ACK=0
  export FLEET_ACK_TIMEOUT_SECONDS=120
  export FLEET_TEARDOWN_GRACE_SECONDS=30
}

teardown() {
  if [ -n "${MONITOR_PID:-}" ]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
  teardown_sandbox
}

write_fake_herdr() {
  cat > "$FAKE_BIN/herdr" <<'HERDR'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "$HERDR_CALLS"

if [ "${1:-}" = agent ] && [ "${2:-}" = list ]; then
  if [ "${HERDR_LIST_MODE:-ok}" = fail ]; then
    printf '{"error":{"code":"server_not_running"}}\n' >&2
    exit 1
  fi
  "$REAL_PYTHON" - "$HERDR_INVENTORY" "${FLEET_WORKSPACE:-w1}" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as source:
    inventory = json.load(source)
for agent in inventory.get("result", {}).get("agents", []):
    if "workspace_id" not in agent:
        agent["workspace_id"] = sys.argv[2]
json.dump(inventory, sys.stdout)
sys.stdout.write("\n")
PYTHON
  exit 0
fi

  if [ "${1:-}" = agent ] && [ "${2:-}" = prompt ]; then
  if [ "${HERDR_REQUIRE_PRESTAMP:-0}" -eq 1 ]; then
    awk -F '\t' '$4 != 0 && $5 == 1 { found = 1 } END { exit !found }' \
      "$FLEET_PENDING" || exit 9
  fi
  if [ "${HERDR_PROMPT_RC:-0}" -ne 0 ]; then
    printf '%s\n' "${HERDR_PROMPT_OUTPUT:-{"error":{"code":"agent_prompt_stalled"}}}" >&2
  fi
  exit "${HERDR_PROMPT_RC:-0}"
fi

printf 'unexpected fake herdr call: %s\n' "$*" >&2
exit 2
HERDR
  chmod +x "$FAKE_BIN/herdr"

  cat > "$FAKE_BIN/git" <<'GIT'
#!/usr/bin/env bash
if [ "${GIT_REV_PARSE_FAIL:-0}" -eq 1 ] &&
  [ "${3:-}" = rev-parse ] && [ "${4:-}" = --short ] && [ "${5:-}" = HEAD ]; then
  exit 1
fi
exec "$REAL_GIT" "$@"
GIT
  chmod +x "$FAKE_BIN/git"

  cat > "$FAKE_BIN/mv" <<'MV'
#!/usr/bin/env bash
destination=''
for argument in "$@"; do
  destination="$argument"
done
if [ -n "${MV_FAIL_DEST:-}" ] && [ "$destination" = "$MV_FAIL_DEST" ]; then
  exit 1
fi
if [ -n "${MV_EMPTY_AFTER_DEST:-}" ] &&
  [ "$destination" = "$MV_EMPTY_AFTER_DEST" ]; then
  "$REAL_MV" "$@"
  status=$?
  [ "$status" -ne 0 ] || : > "$destination"
  exit "$status"
fi
exec "$REAL_MV" "$@"
MV
  chmod +x "$FAKE_BIN/mv"

  cat > "$FAKE_BIN/python3" <<'PYTHON'
#!/usr/bin/env bash
set -u
if [ "${PYTHON_CLOSE_AFTER_ACK:-0}" -eq 1 ] && [ "$#" -eq 4 ] &&
  [ "$1" = - ]; then
  "$REAL_PYTHON" "$@"
  status=$?
  if [ "$status" -eq 3 ]; then
    "$REAL_PYTHON" -c '
import json
import os
import sys

path, event_id = sys.argv[1:]
with open(path) as source:
    config = json.load(source)
for stream in config.get("streams", []):
    for event in stream.get("events", []):
        if event.get("eventId") == event_id:
            event["closedAt"] = "2026-09-04T00:00:00Z"
temporary = path + ".race"
with open(temporary, "w") as target:
    json.dump(config, target)
    target.write("\n")
os.replace(temporary, path)
' "$2" "$3"
  fi
  exit "$status"
fi
exec "$REAL_PYTHON" "$@"
PYTHON
  chmod +x "$FAKE_BIN/python3"
}

write_quiet_inventory() {
  cat > "$HERDR_INVENTORY.tmp" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""}
]}}
JSON
  mv "$HERDR_INVENTORY.tmp" "$HERDR_INVENTORY"
}

write_settled_inventory() {
  cat > "$HERDR_INVENTORY.tmp" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"ticket-impl","agent_status":"done","state_change_seq":7,"terminal_title":""}
]}}
JSON
  mv "$HERDR_INVENTORY.tmp" "$HERDR_INVENTORY"
}

write_empty_fleet() {
  printf '{"workspace":"w1","streams":[]}\n' > "$FLEET_FILE.tmp"
  mv "$FLEET_FILE.tmp" "$FLEET_FILE"
}

write_unacknowledged_fleet() {
  cat > "$FLEET_FILE.tmp" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"implementing",
  "agents":{"impl":{"name":"ticket-impl","role":"impl","dispatchState":"active"}},
  "events":[]
}]}
JSON
  mv "$FLEET_FILE.tmp" "$FLEET_FILE"
}

write_acknowledged_fleet() {
  cat > "$FLEET_FILE.tmp" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-ready",
  "agents":{"impl":{"name":"ticket-impl","role":"impl","dispatchState":"closed"}},
  "events":[{
    "eventId":"ticket-impl@7",
    "agent":"ticket-impl",
    "kind":"review-ready"
  }]
}]}
JSON
  mv "$FLEET_FILE.tmp" "$FLEET_FILE"
}

invoke_monitor() {
  local -a command=(
    env
    -u FLEET_ENV
    -u FLEET_CONFIG
    -u FLEET_STATE_DIR
    -u FLEET_POLL_SECONDS
    -u FLEET_TEARDOWN_GRACE_SECONDS
    -u FLEET_SESSION
    -u FLEET_WORKSPACE
    -u FLEET_COORDINATOR
    -u FLEET_HEARTBEAT
    -u FLEET_SWEPT
    -u FLEET_PENDING
    -u FLEET_DELIVERY_FAILURES
    -u FLEET_LOG
    -u FLEET_CAPTURES_DIR
    -u FLEET_MONITOR_LOCK_DIR
    -u FLEET_MONITOR_LOCK_FILE
    -u FLEET_VERDICT_LANE_GLOBS
    "PATH=$FAKE_BIN:$PATH"
    FLEET_WORKSPACE=w1
    FLEET_COORDINATOR=coordinator
    "FLEET_SEED=$SEED"
    "FLEET_POLL_SECONDS=${FLEET_POLL_SECONDS:-10}"
    "FLEET_ACK_TIMEOUT_SECONDS=$FLEET_ACK_TIMEOUT_SECONDS"
    "FLEET_TEARDOWN_GRACE_SECONDS=$FLEET_TEARDOWN_GRACE_SECONDS"
    "HERDR_INVENTORY=$HERDR_INVENTORY"
    "HERDR_CALLS=$HERDR_CALLS"
    "HERDR_LIST_MODE=$HERDR_LIST_MODE"
    "HERDR_PROMPT_RC=$HERDR_PROMPT_RC"
    "HERDR_PROMPT_OUTPUT=$HERDR_PROMPT_OUTPUT"
    "HERDR_REQUIRE_PRESTAMP=$HERDR_REQUIRE_PRESTAMP"
    "GIT_REV_PARSE_FAIL=$GIT_REV_PARSE_FAIL"
    "REAL_GIT=$REAL_GIT"
    "MV_FAIL_DEST=$MV_FAIL_DEST"
    "MV_EMPTY_AFTER_DEST=$MV_EMPTY_AFTER_DEST"
    "REAL_MV=$REAL_MV"
    "REAL_PYTHON=$REAL_PYTHON"
    "PYTHON_CLOSE_AFTER_ACK=$PYTHON_CLOSE_AFTER_ACK"
    "${MONITOR_SHELL:-bash}" "$MONITOR"
  )
  if [ "${MONITOR_CONTINUOUS:-0}" = 1 ]; then
    exec "${command[@]}"
  fi
  "${command[@]}" --once
}

capture_monitor() {
  local stem="$1"
  if invoke_monitor > "$stem.stdout" 2> "$stem.stderr"; then
    MONITOR_STATUS=0
  else
    MONITOR_STATUS=$?
  fi
}

assert_silent() {
  local stem="$1"
  [ ! -s "$stem.stdout" ]
  [ ! -s "$stem.stderr" ]
}

assert_monitor_ok() {
  local stem="$1"
  if [ "$MONITOR_STATUS" -ne 0 ]; then
    printf 'monitor exited %s\n' "$MONITOR_STATUS" >&2
    cat "$stem.stderr" >&2
    return 1
  fi
}

assert_exact_wake() {
  local stem="$1"
  local message="$2"
  if ! printf '%s\n' "$message" | cmp -s - "$stem.stdout"; then
    printf 'expected stdout: %s\nactual stdout:\n' "$message" >&2
    cat "$stem.stdout" >&2
    return 1
  fi
  [ ! -s "$stem.stderr" ]
}

assert_pending_not_swept() {
  local event_id="$1"
  awk -F '\t' -v id="$event_id" '$1 == id { found = 1 } END { exit !found }' \
    "$PENDING_FILE"
  if [ -f "$SWEPT_FILE" ]; then
    ! grep -Fqx -- "$event_id" "$SWEPT_FILE"
  fi
}

prompt_count() {
  awk '$1 == "agent" && $2 == "prompt" { count++ } END { print count + 0 }' \
    "$HERDR_CALLS"
}

prompt_count_at_least() {
  [ "$(prompt_count)" -ge "$1" ]
}

list_count() {
  awk '$1 == "agent" && $2 == "list" { count++ } END { print count + 0 }' \
    "$HERDR_CALLS"
}

list_count_at_least() {
  [ "$(list_count)" -ge "$1" ]
}

pending_sent() {
  local event_id="$1"
  awk -F '\t' -v id="$event_id" \
    '$1 == id && $4 != 0 { found = 1 } END { exit !found }' \
    "$PENDING_FILE" 2>/dev/null
}

pending_absent() {
  local event_id="$1"
  [ ! -f "$PENDING_FILE" ] ||
    ! awk -F '\t' -v id="$event_id" \
      '$1 == id { found = 1 } END { exit !found }' "$PENDING_FILE"
}

swept_contains() {
  grep -Fqx -- "$1" "$SWEPT_FILE" 2>/dev/null
}

log_contains() {
  grep -Fq -- "$1" "$LOG_FILE" 2>/dev/null
}

file_contains_line() {
  grep -Fqx -- "$2" "$1" 2>/dev/null
}

file_line_count_at_least() {
  local count
  count="$(grep -Fxc -- "$2" "$1" 2>/dev/null || true)"
  [ "$count" -ge "$3" ]
}

lock_owned_by() {
  [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$1" ]
}

path_absent() {
  [ ! -e "$1" ]
}

wait_until() {
  local description="$1"
  shift
  for _ in $(seq 1 160); do
    if "$@"; then
      return 0
    fi
    sleep 0.05
  done
  printf 'timed out waiting for %s\n' "$description" >&2
  return 1
}

start_monitor() {
  local stem="$1"
  MONITOR_CONTINUOUS=1 invoke_monitor > "$stem.stdout" 2> "$stem.stderr" &
  MONITOR_PID=$!
}

stop_monitor() {
  kill "$MONITOR_PID"
  wait "$MONITOR_PID" 2>/dev/null || true
  unset MONITOR_PID
}

@test "fleet env defaults to a ten-second poll, teardown grace, and seed-local runtime files" {
  local expected

  run bash -c '
    unset FLEET_POLL_SECONDS FLEET_TEARDOWN_GRACE_SECONDS FLEET_STATE_DIR FLEET_CONFIG
    FLEET_SEED="$1"
    . "$2"
    fleet_env_load
    printf "%s\n%s\n%s\n%s\n" \
      "$FLEET_POLL_SECONDS" "$FLEET_TEARDOWN_GRACE_SECONDS" \
      "$FLEET_STATE_DIR" "$FLEET_CONFIG"
  ' bash "$SEED" "$ENV_SCRIPT"

  [ "$status" -eq 0 ]
  expected="$(printf '10\n30\n%s/temp/fleet\n%s/temp/fleet/fleet.json' "$SEED" "$SEED")"
  [ "$output" = "$expected" ]
  git -C "$SEED" check-ignore -q -- "$STATE_DIR"
}

@test "healthy one-shot poll emits exactly zero bytes" {
  write_quiet_inventory
  write_empty_fleet

  capture_monitor "$SANDBOX/quiet"

  assert_monitor_ok "$SANDBOX/quiet"
  assert_silent "$SANDBOX/quiet"
}

@test "monitor ignores agents from another project workspace" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","workspace_id":"w1","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"other-worker","workspace_id":"w2","agent_status":"done","state_change_seq":9,"terminal_title":""}
]}}
JSON
  write_empty_fleet

  capture_monitor "$SANDBOX/workspace-isolation"

  assert_monitor_ok "$SANDBOX/workspace-isolation"
  assert_silent "$SANDBOX/workspace-isolation"
  pending_absent "other-worker@9"
}

@test "monitor fails closed when fleet workspace disagrees" {
  write_quiet_inventory
  printf '{"workspace":"w2","streams":[]}\n' > "$FLEET_FILE"

  capture_monitor "$SANDBOX/workspace-drift"

  assert_monitor_ok "$SANDBOX/workspace-drift"
  assert_exact_wake "$SANDBOX/workspace-drift" "WAKE state fleet.json"
}

@test "monitor fails closed when fleet workspace is missing" {
  write_quiet_inventory
  printf '{"streams":[]}\n' > "$FLEET_FILE"

  capture_monitor "$SANDBOX/workspace-missing"

  assert_monitor_ok "$SANDBOX/workspace-missing"
  assert_exact_wake "$SANDBOX/workspace-missing" "WAKE state fleet.json"
}

@test "monitor rejects a non-string fleet session" {
  write_quiet_inventory
  printf '{"workspace":"w1","session":false,"streams":[]}\n' > "$FLEET_FILE"

  capture_monitor "$SANDBOX/session-invalid"

  assert_monitor_ok "$SANDBOX/session-invalid"
  assert_exact_wake "$SANDBOX/session-invalid" "WAKE state fleet.json"
}

@test "monitor rejects conflicting agent workspace identities" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"worker","workspace_id":"w1","pane_id":"w2:p9","agent_status":"working","state_change_seq":3,"terminal_title":""}
]}}
JSON
  write_empty_fleet

  capture_monitor "$SANDBOX/workspace-conflict"

  assert_monitor_ok "$SANDBOX/workspace-conflict"
  assert_exact_wake "$SANDBOX/workspace-conflict" "WAKE inventory"
}

@test "continuous monitor launches without arguments under macOS bash" {
  [ -x /bin/bash ] || skip "/bin/bash is unavailable"
  write_quiet_inventory
  write_empty_fleet
  export FLEET_POLL_SECONDS=1
  export MONITOR_SHELL=/bin/bash

  start_monitor "$SANDBOX/bash-3-continuous"
  wait_until 'macOS bash monitor first poll' list_count_at_least 1
  sleep 1
  kill -0 "$MONITOR_PID"
  stop_monitor

  assert_silent "$SANDBOX/bash-3-continuous"
}

@test "singleton lock rejects an overlapping monitor and releases on exit" {
  write_quiet_inventory
  write_empty_fleet
  export FLEET_POLL_SECONDS=2

  start_monitor "$SANDBOX/primary"
  wait_until 'primary monitor lock' lock_owned_by "$MONITOR_PID"
  wait_until 'primary monitor first poll' list_count_at_least 1
  local calls_before
  calls_before="$(list_count)"

  capture_monitor "$SANDBOX/overlap"

  if [ "$MONITOR_STATUS" -ne 2 ]; then
    printf 'overlapping monitor exited %s\n' "$MONITOR_STATUS" >&2
    cat "$SANDBOX/overlap.stdout" "$SANDBOX/overlap.stderr" >&2
    return 1
  fi
  [ ! -s "$SANDBOX/overlap.stdout" ]
  printf 'fleet-monitor: already running\n' |
    cmp -s - "$SANDBOX/overlap.stderr"
  [ "$(list_count)" -eq "$calls_before" ]

  stop_monitor
  assert_silent "$SANDBOX/primary"
  [ -f "$LOCK_FILE" ]

  capture_monitor "$SANDBOX/reacquired"
  assert_monitor_ok "$SANDBOX/reacquired"
  assert_silent "$SANDBOX/reacquired"
  [ "$(list_count)" -eq $((calls_before + 1)) ]
}

@test "stale lock-file metadata never blocks restart" {
  write_quiet_inventory
  write_empty_fleet
  printf '99999999\n' > "$LOCK_FILE"

  capture_monitor "$SANDBOX/stale-lock"

  assert_monitor_ok "$SANDBOX/stale-lock"
  assert_silent "$SANDBOX/stale-lock"
  [ "$(list_count)" -eq 1 ]
  [ "$(cat "$LOCK_FILE")" != 99999999 ]
}

@test "SIGKILL releases the singleton lock for immediate restart" {
  write_quiet_inventory
  write_empty_fleet
  export FLEET_POLL_SECONDS=30

  start_monitor "$SANDBOX/killed"
  wait_until 'monitor lock' lock_owned_by "$MONITOR_PID"
  wait_until 'monitor first poll' list_count_at_least 1
  local calls_before
  calls_before="$(list_count)"
  kill -KILL "$MONITOR_PID"
  wait "$MONITOR_PID" 2>/dev/null || true
  unset MONITOR_PID

  capture_monitor "$SANDBOX/restart-after-kill"

  assert_monitor_ok "$SANDBOX/restart-after-kill"
  assert_silent "$SANDBOX/restart-after-kill"
  [ "$(list_count)" -eq $((calls_before + 1)) ]
}

@test "legacy bare swept lane cannot suppress an unacknowledged settlement" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"ticket-impl","agent_status":"working","state_change_seq":6,"terminal_title":""}
]}}
JSON
  write_unacknowledged_fleet
  printf 'ticket-impl\n' > "$SWEPT_FILE"
  export FLEET_POLL_SECONDS=1

  start_monitor "$SANDBOX/legacy-swept"
  wait_until 'working baseline completion' list_count_at_least 2

  write_settled_inventory
  wait_until 'post-settlement delivery' prompt_count_at_least 1
  stop_monitor

  assert_silent "$SANDBOX/legacy-swept"
  [ "$(prompt_count)" -eq 1 ]
  assert_pending_not_swept 'ticket-impl@7'
  grep -Fqx -- 'ticket-impl' "$SWEPT_FILE"
}

@test "historical closed event does not hide a reused active lane" {
  write_settled_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"implementing",
  "agents":{"impl":{"name":"ticket-impl","role":"impl","dispatchState":"active"}},
  "events":[{
    "eventId":"ticket-impl@1",
    "agent":"ticket-impl",
    "kind":"review-ready",
    "closedAt":"2026-09-04T00:00:00Z"
  }]
}]}
JSON

  capture_monitor "$SANDBOX/reused-active"

  assert_monitor_ok "$SANDBOX/reused-active"
  assert_silent "$SANDBOX/reused-active"
  [ "$(prompt_count)" -eq 1 ]
  assert_pending_not_swept 'ticket-impl@7'
}

@test "later same-name record cannot acknowledge an older open event" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-2",
  "agents":{"impl":{
    "name":"ticket-impl",
    "role":"impl",
    "dispatchState":"closed",
    "captureEventId":"ticket-impl@9"
  }},
  "events":[
    {
      "eventId":"ticket-impl@7",
      "agent":"ticket-impl",
      "kind":"review-ready"
    },
    {
      "eventId":"ticket-impl@9",
      "agent":"ticket-impl",
      "kind":"review-ready",
      "closedAt":"2026-09-04T00:00:00Z"
    }
  ]
}]}
JSON
  printf 'ticket-impl@7\tticket-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/reused-open-event"

  assert_monitor_ok "$SANDBOX/reused-open-event"
  assert_exact_wake "$SANDBOX/reused-open-event" 'WAKE teardown ticket-impl@7'
  assert_pending_not_swept 'ticket-impl@7'
}

@test "event-level close survives current role-slot replacement" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"new-impl","agent_status":"working","state_change_seq":2,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"implementing",
  "agents":{"impl":{"name":"new-impl","role":"impl","dispatchState":"active"}},
  "events":[{
    "eventId":"old-impl@7",
    "agent":"old-impl",
    "kind":"review-ready",
    "closedAt":"2026-09-04T00:00:00Z"
  }]
}]}
JSON
  printf 'old-impl@7\told-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/event-close-proof"

  assert_monitor_ok "$SANDBOX/event-close-proof"
  assert_silent "$SANDBOX/event-close-proof"
  pending_absent 'old-impl@7'
  swept_contains 'old-impl@7'
}

@test "newly first-seen done lane stays pending until fleet state acknowledges it" {
  write_settled_inventory
  write_unacknowledged_fleet

  capture_monitor "$SANDBOX/delivered"

  assert_monitor_ok "$SANDBOX/delivered"
  assert_silent "$SANDBOX/delivered"
  [ "$(prompt_count)" -eq 1 ]
  grep -Fq -- 'agent prompt coordinator' "$HERDR_CALLS"
  grep -Fq -- 'ticket-impl@7' "$HERDR_CALLS"
  assert_pending_not_swept 'ticket-impl@7'
}

@test "failed delivery wakes once and does not sweep the pending event" {
  write_settled_inventory
  write_unacknowledged_fleet
  export HERDR_PROMPT_RC=1

  capture_monitor "$SANDBOX/failed"

  assert_monitor_ok "$SANDBOX/failed"
  assert_exact_wake "$SANDBOX/failed" 'WAKE delivery ticket-impl@7'
  [ "$(prompt_count)" -eq 1 ]
  assert_pending_not_swept 'ticket-impl@7'
}

@test "failed prompt payload is bounded in the log and absent from monitor output" {
  local failure_line detail padding
  write_settled_inventory
  write_unacknowledged_fleet
  export HERDR_PROMPT_RC=1
  printf -v padding '%0300d' 0
  HERDR_PROMPT_OUTPUT="line one
line	two $padding TAIL_MARKER"
  export HERDR_PROMPT_OUTPUT

  capture_monitor "$SANDBOX/failed-diagnostic"

  assert_monitor_ok "$SANDBOX/failed-diagnostic"
  assert_exact_wake "$SANDBOX/failed-diagnostic" 'WAKE delivery ticket-impl@7'
  run ! grep -Fq 'line one' "$SANDBOX/failed-diagnostic.stdout"
  failure_line="$(grep -F 'delivery failed: ticket-impl@7 (' "$LOG_FILE")"
  detail="${failure_line#* (}"
  detail="${detail%)}"
  [[ "$detail" == line\ one\ line\ two* ]]
  [ "${#detail}" -le 240 ]
  [[ "$failure_line" != *TAIL_MARKER* ]]
}

@test "failed delivery is timestamped and does not retry before timeout" {
  write_settled_inventory
  write_unacknowledged_fleet
  export HERDR_PROMPT_RC=1

  capture_monitor "$SANDBOX/delivery-first"
  assert_exact_wake "$SANDBOX/delivery-first" 'WAKE delivery ticket-impl@7'

  capture_monitor "$SANDBOX/delivery-repeat"
  assert_monitor_ok "$SANDBOX/delivery-repeat"
  assert_silent "$SANDBOX/delivery-repeat"
  [ "$(prompt_count)" -eq 1 ]
  awk -F '\t' \
    '$1 == "ticket-impl@7" && $4 != 0 && $5 == 1 { found = 1 }
     END { exit !found }' "$PENDING_FILE"
  assert_pending_not_swept 'ticket-impl@7'
}

@test "delivery attempt is durable before Herdr receives the prompt" {
  write_settled_inventory
  write_unacknowledged_fleet
  export HERDR_REQUIRE_PRESTAMP=1

  capture_monitor "$SANDBOX/prestamped"

  assert_monitor_ok "$SANDBOX/prestamped"
  assert_silent "$SANDBOX/prestamped"
  [ "$(prompt_count)" -eq 1 ]
  pending_sent 'ticket-impl@7'
}

@test "pending event retries and sweeps only after its fleet event appears" {
  write_settled_inventory
  write_unacknowledged_fleet
  export HERDR_PROMPT_RC=1
  capture_monitor "$SANDBOX/first-attempt"
  assert_exact_wake "$SANDBOX/first-attempt" 'WAKE delivery ticket-impl@7'
  assert_pending_not_swept 'ticket-impl@7'

  awk -F '\t' -v OFS='\t' '{$4 = 1; print}' "$PENDING_FILE" \
    > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1
  export HERDR_PROMPT_RC=0
  capture_monitor "$SANDBOX/retry"
  assert_monitor_ok "$SANDBOX/retry"
  assert_exact_wake "$SANDBOX/retry" 'WAKE unacked ticket-impl@7'
  [ "$(prompt_count)" -eq 2 ]
  assert_pending_not_swept 'ticket-impl@7'

  write_acknowledged_fleet
  capture_monitor "$SANDBOX/acknowledged"
  assert_monitor_ok "$SANDBOX/acknowledged"
  assert_silent "$SANDBOX/acknowledged"
  [ "$(prompt_count)" -eq 2 ]
  run ! awk -F '\t' -v id='ticket-impl@7' \
    '$1 == id { found = 1 } END { exit !found }' "$PENDING_FILE"
  grep -Fqx -- 'ticket-impl@7' "$SWEPT_FILE"
}

@test "accepted but unacknowledged event wakes tersely and retries after timeout" {
  write_settled_inventory
  write_unacknowledged_fleet

  capture_monitor "$SANDBOX/unacked-first"
  assert_monitor_ok "$SANDBOX/unacked-first"
  assert_silent "$SANDBOX/unacked-first"
  [ "$(prompt_count)" -eq 1 ]

  awk -F '\t' -v OFS='\t' '{$4 = 1; print}' "$PENDING_FILE" \
    > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1

  capture_monitor "$SANDBOX/unacked-retry"
  assert_monitor_ok "$SANDBOX/unacked-retry"
  assert_exact_wake "$SANDBOX/unacked-retry" 'WAKE unacked ticket-impl@7'
  [ "$(prompt_count)" -eq 2 ]
  assert_pending_not_swept 'ticket-impl@7'
}

@test "second retry waits for two acknowledgement windows" {
  local now
  write_settled_inventory
  write_unacknowledged_fleet
  export FLEET_ACK_TIMEOUT_SECONDS=10

  capture_monitor "$SANDBOX/backoff-first"
  assert_monitor_ok "$SANDBOX/backoff-first"
  assert_silent "$SANDBOX/backoff-first"
  [ "$(prompt_count)" -eq 1 ]

  now="$(date +%s)"
  awk -F '\t' -v OFS='\t' -v sent=$((now - 15)) \
    '{$4 = sent; $5 = 2; print}' "$PENDING_FILE" > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  capture_monitor "$SANDBOX/backoff-too-early"
  assert_monitor_ok "$SANDBOX/backoff-too-early"
  assert_silent "$SANDBOX/backoff-too-early"
  [ "$(prompt_count)" -eq 1 ]

  now="$(date +%s)"
  awk -F '\t' -v OFS='\t' -v sent=$((now - 21)) \
    '{$4 = sent; print}' "$PENDING_FILE" > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  capture_monitor "$SANDBOX/backoff-due"
  assert_monitor_ok "$SANDBOX/backoff-due"
  assert_exact_wake "$SANDBOX/backoff-due" 'WAKE unacked ticket-impl@7'
  [ "$(prompt_count)" -eq 2 ]
  awk -F '\t' \
    '$1 == "ticket-impl@7" && $5 == 3 { found = 1 }
     END { exit !found }' "$PENDING_FILE"
}

@test "overdue event wakes while coordinator is busy and re-prompts only when idle" {
  write_settled_inventory
  write_unacknowledged_fleet

  capture_monitor "$SANDBOX/busy-first"
  assert_monitor_ok "$SANDBOX/busy-first"
  assert_silent "$SANDBOX/busy-first"
  [ "$(prompt_count)" -eq 1 ]

  awk -F '\t' -v OFS='\t' '{$4 = 1; print}' "$PENDING_FILE" \
    > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1
  cat > "$HERDR_INVENTORY.tmp" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"working","state_change_seq":4,"terminal_title":""},
  {"name":"ticket-impl","agent_status":"done","state_change_seq":7,"terminal_title":""}
]}}
JSON
  mv "$HERDR_INVENTORY.tmp" "$HERDR_INVENTORY"

  capture_monitor "$SANDBOX/busy-overdue"
  assert_monitor_ok "$SANDBOX/busy-overdue"
  assert_exact_wake "$SANDBOX/busy-overdue" 'WAKE unacked ticket-impl@7'
  [ "$(prompt_count)" -eq 1 ]
  awk -F '\t' \
    '$1 == "ticket-impl@7" && $4 == 1 && $5 == 1 { found = 1 }
     END { exit !found }' "$PENDING_FILE"

  capture_monitor "$SANDBOX/busy-repeat"
  assert_monitor_ok "$SANDBOX/busy-repeat"
  assert_silent "$SANDBOX/busy-repeat"
  [ "$(prompt_count)" -eq 1 ]

  write_settled_inventory
  capture_monitor "$SANDBOX/idle-retry"
  assert_monitor_ok "$SANDBOX/idle-retry"
  assert_silent "$SANDBOX/idle-retry"
  [ "$(prompt_count)" -eq 2 ]
  assert_pending_not_swept 'ticket-impl@7'
}

@test "simultaneous routine settles use one coordinator prompt" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"first-impl","agent_status":"done","state_change_seq":7,"terminal_title":""},
  {"name":"second-impl","agent_status":"idle","state_change_seq":9,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[
  {"ticket":"T1","agents":{"impl":{"name":"first-impl","role":"impl","dispatchState":"active"}},"events":[]},
  {"ticket":"T2","agents":{"impl":{"name":"second-impl","role":"impl","dispatchState":"active"}},"events":[]}
]}
JSON

  capture_monitor "$SANDBOX/batch"

  assert_monitor_ok "$SANDBOX/batch"
  assert_silent "$SANDBOX/batch"
  [ "$(prompt_count)" -eq 1 ]
  grep -Fq -- 'first-impl@7' "$HERDR_CALLS"
  grep -Fq -- 'second-impl@9' "$HERDR_CALLS"
  assert_pending_not_swept 'first-impl@7'
  assert_pending_not_swept 'second-impl@9'
}

@test "explicit implementer role overrides review-shaped ticket and lane names" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"review-fix-review-1","agent_status":"done","state_change_seq":12,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"REVIEW-FIX",
  "agents":{"impl":{"name":"review-fix-review-1","role":"impl","dispatchState":"active"}},
  "events":[]
}]}
JSON

  capture_monitor "$SANDBOX/role-routing"

  assert_monitor_ok "$SANDBOX/role-routing"
  assert_silent "$SANDBOX/role-routing"
  [ "$(prompt_count)" -eq 1 ]
  grep -Fq -- 'agent prompt coordinator' "$HERDR_CALLS"
  grep -Fq -- 'review-fix-review-1@12' "$HERDR_CALLS"
  awk -F '\t' \
    '$1 == "review-fix-review-1@12" && $6 == "coordinator" { found = 1 }
     END { exit !found }' "$PENDING_FILE"
}

@test "verdict wake remains pending and quiet until its exact capture ack" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"opaque-worker","agent_status":"done","state_change_seq":8,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "agents":{"review":{"name":"opaque-worker","role":"review","dispatchState":"active"}},
  "events":[]
}]}
JSON

  capture_monitor "$SANDBOX/verdict-first"
  assert_monitor_ok "$SANDBOX/verdict-first"
  assert_exact_wake "$SANDBOX/verdict-first" 'WAKE verdict opaque-worker@8'
  [ "$(prompt_count)" -eq 0 ]
  assert_pending_not_swept 'opaque-worker@8'

  capture_monitor "$SANDBOX/verdict-waiting"
  assert_monitor_ok "$SANDBOX/verdict-waiting"
  assert_silent "$SANDBOX/verdict-waiting"
  assert_pending_not_swept 'opaque-worker@8'

  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "agents":{"review":{"name":"opaque-worker","role":"review","dispatchState":"closed"}},
  "events":[{
    "eventId":"opaque-worker@8",
    "agent":"opaque-worker",
    "kind":"verdict"
  }]
}]}
JSON
  capture_monitor "$SANDBOX/verdict-acked"
  assert_monitor_ok "$SANDBOX/verdict-acked"
  assert_silent "$SANDBOX/verdict-acked"
  run ! awk -F '\t' '$1 == "opaque-worker@8" { found = 1 } END { exit !found }' \
    "$PENDING_FILE"
  grep -Fqx -- 'opaque-worker@8' "$SWEPT_FILE"
}

@test "done to idle status flap stays one logical settlement" {
  write_settled_inventory
  write_unacknowledged_fleet
  export FLEET_POLL_SECONDS=1

  start_monitor "$SANDBOX/flap"
  wait_until 'initial settlement delivery' prompt_count_at_least 1

  write_acknowledged_fleet
  cat > "$HERDR_INVENTORY.tmp" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"ticket-impl","agent_status":"idle","state_change_seq":8,"terminal_title":""}
]}}
JSON
  mv "$HERDR_INVENTORY.tmp" "$HERDR_INVENTORY"
  wait_until 'capture acknowledgement' swept_contains 'ticket-impl@7'
  wait_until 'acknowledged pending removal' pending_absent 'ticket-impl@7'
  stop_monitor

  assert_silent "$SANDBOX/flap"
  [ "$(prompt_count)" -eq 1 ]
  pending_absent 'ticket-impl@7'
  run ! awk -F '\t' '$1 == "ticket-impl@8" { found = 1 } END { exit !found }' \
    "$PENDING_FILE"
  run ! grep -Fqx -- 'ticket-impl@8' "$SWEPT_FILE"
}

@test "lane first sampled idle while reserved is captured after activation" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"startup-impl","agent_status":"idle","state_change_seq":5,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"STARTUP",
  "agents":{"impl":{"name":"startup-impl","role":"impl","dispatchState":"reserved"}},
  "events":[]
  }]}
JSON
  export FLEET_POLL_SECONDS=1

  start_monitor "$SANDBOX/startup"
  wait_until 'reserved lane baseline' \
    log_contains 'ignored unregistered settled lane startup-impl'
  [ "$(prompt_count)" -eq 0 ]

  cat > "$HERDR_INVENTORY.tmp" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"startup-impl","agent_status":"done","state_change_seq":7,"terminal_title":""}
]}}
JSON
  mv "$HERDR_INVENTORY.tmp" "$HERDR_INVENTORY"
  cat > "$FLEET_FILE.tmp" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"STARTUP",
  "agents":{"impl":{"name":"startup-impl","role":"impl","dispatchState":"active"}},
  "events":[]
}]}
JSON
  mv "$FLEET_FILE.tmp" "$FLEET_FILE"

  wait_until 'activated lane settlement delivery' prompt_count_at_least 1
  stop_monitor

  assert_silent "$SANDBOX/startup"
  [ "$(prompt_count)" -eq 1 ]
  assert_pending_not_swept 'startup-impl@7'
  pending_absent 'startup-impl@5'
}

@test "startup reconstructs absent active and legacy dispatches" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[
  {"ticket":"ACTIVE","agents":{"impl":{"name":"active-missing","role":"impl","dispatchState":"active"}},"events":[]},
  {"ticket":"LEGACY","agents":{"impl":{"name":"legacy-missing","role":"impl"}},"events":[]}
]}
JSON

  capture_monitor "$SANDBOX/startup-missing"

  assert_monitor_ok "$SANDBOX/startup-missing"
  assert_exact_wake "$SANDBOX/startup-missing" \
    'WAKE vanished active-missing@missing legacy-missing@missing'
  [ "$(prompt_count)" -eq 0 ]
  pending_sent 'active-missing@missing'
  pending_sent 'legacy-missing@missing'
  awk -F '\t' \
    '$1 == "active-missing@missing" && $6 == "vanished" { active = 1 }
     $1 == "legacy-missing@missing" && $6 == "vanished" { legacy = 1 }
     END { exit !(active && legacy) }' "$PENDING_FILE"
}

@test "prompting dispatch is monitor-owned when its completion is already visible" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"prompt-owned","agent_status":"done","state_change_seq":11,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"PROMPTING",
  "agents":{"impl":{"name":"prompt-owned","role":"impl","dispatchState":"prompting"}},
  "events":[]
}]}
JSON

  capture_monitor "$SANDBOX/prompting-complete"

  assert_monitor_ok "$SANDBOX/prompting-complete"
  assert_silent "$SANDBOX/prompting-complete"
  [ "$(prompt_count)" -eq 1 ]
  assert_pending_not_swept 'prompt-owned@11'
  awk -F '\t' \
    '$1 == "prompt-owned@11" && $6 == "coordinator" { found = 1 }
     END { exit !found }' "$PENDING_FILE"
}

@test "captured lane closed between polls does not raise a false vanished wake" {
  write_settled_inventory
  write_unacknowledged_fleet
  export FLEET_POLL_SECONDS=1

  start_monitor "$SANDBOX/close-race"

  wait_until 'initial settlement delivery' prompt_count_at_least 1

  write_acknowledged_fleet
  write_quiet_inventory
  wait_until 'captured settlement sweep' swept_contains 'ticket-impl@7'
  wait_until 'captured pending removal' pending_absent 'ticket-impl@7'
  stop_monitor

  assert_silent "$SANDBOX/close-race"
  pending_absent 'ticket-impl@7'
  grep -Fqx -- 'ticket-impl@7' "$SWEPT_FILE"
}

@test "vanished lane persists and retries until durable resolution" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"vanish-impl","agent_status":"done","state_change_seq":4,"terminal_title":""}
]}}
JSON
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"VANISH",
  "agents":{"impl":{"name":"vanish-impl","role":"impl","dispatchState":"active"}},
  "events":[]
}]}
JSON
  export FLEET_POLL_SECONDS=1
  start_monitor "$SANDBOX/vanished"
  wait_until 'initial coordinator delivery' prompt_count_at_least 1
  [ "$(prompt_count)" -eq 1 ]

  write_quiet_inventory
  wait_until 'first vanished wake' file_contains_line \
    "$SANDBOX/vanished.stdout" 'WAKE vanished vanish-impl@4'
  wait_until 'persisted vanished event' pending_sent 'vanish-impl@4'
  stop_monitor

  assert_exact_wake "$SANDBOX/vanished" 'WAKE vanished vanish-impl@4'
  awk -F '\t' \
    '$1 == "vanish-impl@4" && $5 == 2 && $6 == "vanished" { found = 1 }
     END { exit !found }' "$PENDING_FILE"
  run ! awk -F '\t' '$1 == "vanish-impl@missing" { found = 1 } END { exit !found }' \
    "$PENDING_FILE"

  capture_monitor "$SANDBOX/vanished-restart"
  assert_monitor_ok "$SANDBOX/vanished-restart"
  assert_silent "$SANDBOX/vanished-restart"

  awk -F '\t' -v OFS='\t' '{$4 = 1; print}' "$PENDING_FILE" \
    > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1
  capture_monitor "$SANDBOX/vanished-retry"
  assert_monitor_ok "$SANDBOX/vanished-retry"
  assert_exact_wake "$SANDBOX/vanished-retry" 'WAKE vanished vanish-impl@4'
  awk -F '\t' \
    '$1 == "vanish-impl@4" && $5 == 3 && $6 == "vanished" { found = 1 }
     END { exit !found }' "$PENDING_FILE"

  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"VANISH",
  "phase":"hold",
  "agents":{"impl":{"name":"vanish-impl","role":"impl","dispatchState":"resolved"}},
  "events":[{
    "eventId":"vanish-impl@4",
    "agent":"vanish-impl",
    "kind":"resolved-lost-output"
  }]
}]}
JSON
  capture_monitor "$SANDBOX/vanished-resolved"
  assert_monitor_ok "$SANDBOX/vanished-resolved"
  assert_silent "$SANDBOX/vanished-resolved"
  pending_absent 'vanish-impl@4'
  swept_contains 'vanish-impl@4'
}

@test "valid empty inventory still reconstructs config-owned missing lanes" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[]}}
JSON
  write_unacknowledged_fleet

  capture_monitor "$SANDBOX/empty-recovery"

  assert_monitor_ok "$SANDBOX/empty-recovery"
  printf '%s\n' \
    'WAKE inventory' \
    'WAKE vanished ticket-impl@missing' |
    cmp -s - "$SANDBOX/empty-recovery.stdout"
  [ ! -s "$SANDBOX/empty-recovery.stderr" ]
  [ "$(prompt_count)" -eq 0 ]
  assert_pending_not_swept 'ticket-impl@missing'
}

@test "unreadable fleet state suppresses pending redelivery until ACKs are knowable" {
  write_settled_inventory
  write_unacknowledged_fleet
  capture_monitor "$SANDBOX/config-good"
  assert_monitor_ok "$SANDBOX/config-good"
  assert_silent "$SANDBOX/config-good"
  [ "$(prompt_count)" -eq 1 ]

  awk -F '\t' -v OFS='\t' '{$4 = 1; print}' "$PENDING_FILE" \
    > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1
  printf '{broken\n' > "$FLEET_FILE"

  capture_monitor "$SANDBOX/config-bad"

  assert_monitor_ok "$SANDBOX/config-bad"
  assert_exact_wake "$SANDBOX/config-bad" 'WAKE state fleet.json'
  [ "$(prompt_count)" -eq 1 ]
  assert_pending_not_swept 'ticket-impl@7'
}

@test "valid JSON with an invalid fleet shape is treated as unreadable" {
  write_quiet_inventory
  printf 'ticket-impl@7\tticket-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"
  printf '{"workspace":"w1","streams":null}\n' > "$FLEET_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1

  capture_monitor "$SANDBOX/config-shape-bad"

  assert_monitor_ok "$SANDBOX/config-shape-bad"
  assert_exact_wake "$SANDBOX/config-shape-bad" 'WAKE state fleet.json'
  [ "$(prompt_count)" -eq 0 ]
  assert_pending_not_swept 'ticket-impl@7'
}

@test "unreadable pending queue is preserved and its alarm rearms" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "agents":{"impl":{"name":"ticket-impl","role":"impl","dispatchState":"closed"}},
  "events":[
    {"eventId":"ticket-impl@7","agent":"ticket-impl","kind":"review-ready","closedAt":"2026-09-04T00:00:00Z"},
    {"eventId":"ticket-impl@8","agent":"ticket-impl","kind":"review-ready"}
  ]
}]}
JSON
  printf 'ticket-impl@7\tticket-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"
  chmod 000 "$PENDING_FILE"

  capture_monitor "$SANDBOX/pending-unreadable-1"
  assert_monitor_ok "$SANDBOX/pending-unreadable-1"
  assert_exact_wake "$SANDBOX/pending-unreadable-1" 'WAKE state pending'

  capture_monitor "$SANDBOX/pending-unreadable-2"
  assert_monitor_ok "$SANDBOX/pending-unreadable-2"
  assert_silent "$SANDBOX/pending-unreadable-2"

  chmod 600 "$PENDING_FILE"
  grep -Fqx $'ticket-impl@7\tticket-impl\tdone\t1\t1\tcoordinator' "$PENDING_FILE"
  capture_monitor "$SANDBOX/pending-recovered"
  assert_monitor_ok "$SANDBOX/pending-recovered"
  assert_silent "$SANDBOX/pending-recovered"
  pending_absent 'ticket-impl@7'

  printf 'ticket-impl@8\tticket-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"
  chmod 000 "$PENDING_FILE"
  capture_monitor "$SANDBOX/pending-unreadable-again"
  chmod 600 "$PENDING_FILE"
  assert_monitor_ok "$SANDBOX/pending-unreadable-again"
  assert_exact_wake "$SANDBOX/pending-unreadable-again" 'WAKE state pending'
  grep -Fqx $'ticket-impl@8\tticket-impl\tdone\t1\t1\tcoordinator' "$PENDING_FILE"
}

@test "write-only pending queue never grows duplicate events" {
  local expected
  write_settled_inventory
  write_unacknowledged_fleet
  expected=$'ticket-impl@7\tticket-impl\tdone\t0\t0\tcoordinator'
  printf '%s\n' "$expected" > "$PENDING_FILE"
  chmod 200 "$PENDING_FILE"

  capture_monitor "$SANDBOX/pending-write-only-1"
  assert_monitor_ok "$SANDBOX/pending-write-only-1"
  assert_exact_wake "$SANDBOX/pending-write-only-1" 'WAKE state pending'
  [ "$(prompt_count)" -eq 0 ]

  capture_monitor "$SANDBOX/pending-write-only-2"
  assert_monitor_ok "$SANDBOX/pending-write-only-2"
  assert_silent "$SANDBOX/pending-write-only-2"
  [ "$(prompt_count)" -eq 0 ]

  chmod 600 "$PENDING_FILE"
  grep -Fxc -- "$expected" "$PENDING_FILE" | grep -qx 1
  capture_monitor "$SANDBOX/pending-write-only-recovered"
  assert_monitor_ok "$SANDBOX/pending-write-only-recovered"
  assert_silent "$SANDBOX/pending-write-only-recovered"
  [ "$(prompt_count)" -eq 1 ]
  [ "$(awk -F '\t' '$1 == "ticket-impl@7" { count++ } END { print count + 0 }' "$PENDING_FILE")" -eq 1 ]
}

@test "empty unreadable pending queue wakes and rearms" {
  write_quiet_inventory
  write_empty_fleet
  : > "$PENDING_FILE"
  chmod 200 "$PENDING_FILE"

  capture_monitor "$SANDBOX/pending-empty-unreadable-1"
  assert_monitor_ok "$SANDBOX/pending-empty-unreadable-1"
  assert_exact_wake "$SANDBOX/pending-empty-unreadable-1" 'WAKE state pending'

  capture_monitor "$SANDBOX/pending-empty-unreadable-2"
  assert_monitor_ok "$SANDBOX/pending-empty-unreadable-2"
  assert_silent "$SANDBOX/pending-empty-unreadable-2"

  chmod 600 "$PENDING_FILE"
  capture_monitor "$SANDBOX/pending-empty-recovered"
  assert_monitor_ok "$SANDBOX/pending-empty-recovered"
  assert_silent "$SANDBOX/pending-empty-recovered"

  chmod 200 "$PENDING_FILE"
  capture_monitor "$SANDBOX/pending-empty-unreadable-again"
  chmod 600 "$PENDING_FILE"
  assert_monitor_ok "$SANDBOX/pending-empty-unreadable-again"
  assert_exact_wake "$SANDBOX/pending-empty-unreadable-again" 'WAKE state pending'
}

@test "delivery stops when its durable pending row disappears" {
  write_settled_inventory
  write_unacknowledged_fleet
  printf 'ticket-impl@7\tticket-impl\tdone\t0\t0\tcoordinator\n' > "$PENDING_FILE"
  export MV_EMPTY_AFTER_DEST="$PENDING_FILE"

  capture_monitor "$SANDBOX/pending-row-lost"

  assert_monitor_ok "$SANDBOX/pending-row-lost"
  assert_exact_wake "$SANDBOX/pending-row-lost" 'WAKE state pending'
  [ "$(prompt_count)" -eq 0 ]
  [ ! -s "$PENDING_FILE" ]
}

@test "noncanonical pending counters wake once without arithmetic errors" {
  write_quiet_inventory
  write_empty_fleet
  printf 'ghost@7\tghost\tdone\t08\t09\tcoordinator\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/pending-number-1"
  assert_monitor_ok "$SANDBOX/pending-number-1"
  assert_exact_wake "$SANDBOX/pending-number-1" 'WAKE state pending'
  grep -Fqx $'ghost@7\tghost\tdone\t08\t09\tcoordinator' "$PENDING_FILE"

  capture_monitor "$SANDBOX/pending-number-2"
  assert_monitor_ok "$SANDBOX/pending-number-2"
  assert_silent "$SANDBOX/pending-number-2"
  grep -Fqx $'ghost@7\tghost\tdone\t08\t09\tcoordinator' "$PENDING_FILE"

  printf 'ghost@7\tghost\tdone\t0\t0\tcoordinator\n' > "$PENDING_FILE"
  capture_monitor "$SANDBOX/pending-number-recovered"
  assert_monitor_ok "$SANDBOX/pending-number-recovered"
  assert_silent "$SANDBOX/pending-number-recovered"
  run ! grep -Fqx 'state:pending' "$STATE_DIR/fleet-monitor.delivery-failures"
}

@test "captured without a timestamp enters durable teardown recovery" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-1",
  "agents":{"impl":{"name":"ticket-impl","role":"impl","dispatchState":"captured"}},
  "events":[{"eventId":"ticket-impl@7","agent":"ticket-impl","kind":"review-ready"}]
}]}
JSON

  capture_monitor "$SANDBOX/teardown-1"
  assert_monitor_ok "$SANDBOX/teardown-1"
  assert_exact_wake "$SANDBOX/teardown-1" 'WAKE teardown ticket-impl@7'
  assert_pending_not_swept 'ticket-impl@7'
  awk -F '\t' \
    '$1 == "ticket-impl@7" && $5 == 1 && $6 == "teardown" { found = 1 }
     END { exit !found }' "$PENDING_FILE"

  capture_monitor "$SANDBOX/teardown-2"
  assert_monitor_ok "$SANDBOX/teardown-2"
  assert_silent "$SANDBOX/teardown-2"

  printf 'teardown:ticket-impl\n' >> "$STATE_DIR/fleet-monitor.delivery-failures"

  python3 - "$FLEET_FILE" <<'PYTHON'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    config = json.load(fh)
config["streams"][0]["agents"]["impl"]["dispatchState"] = "closed"
with open(path, "w") as fh:
    json.dump(config, fh)
PYTHON
  capture_monitor "$SANDBOX/teardown-closed"
  assert_monitor_ok "$SANDBOX/teardown-closed"
  assert_silent "$SANDBOX/teardown-closed"
  pending_absent 'ticket-impl@7'
  run ! grep -Fqx 'teardown:ticket-impl' "$STATE_DIR/fleet-monitor.delivery-failures"

  python3 - "$FLEET_FILE" <<'PYTHON'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    config = json.load(fh)
config["streams"][0]["agents"]["impl"]["dispatchState"] = "captured"
config["streams"][0]["agents"]["impl"].pop("capturedAt", None)
with open(path, "w") as fh:
    json.dump(config, fh)
PYTHON
  capture_monitor "$SANDBOX/teardown-rearmed"
  assert_monitor_ok "$SANDBOX/teardown-rearmed"
  assert_exact_wake "$SANDBOX/teardown-rearmed" 'WAKE teardown ticket-impl@7'
}

@test "legacy capture without an event ID gets a stable teardown ID" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-1",
  "agents":{"impl":{"name":"legacy-impl","role":"impl","dispatchState":"captured"}},
  "events":[{"agent":"legacy-impl","kind":"review-ready"}]
}]}
JSON

  capture_monitor "$SANDBOX/teardown-legacy"
  assert_monitor_ok "$SANDBOX/teardown-legacy"
  assert_exact_wake "$SANDBOX/teardown-legacy" 'WAKE teardown legacy-impl@captured'
  awk -F '\t' \
    '$1 == "legacy-impl@captured" && $5 == 1 && $6 == "teardown" { found = 1 }
     END { exit !found }' "$PENDING_FILE"
}

@test "captured event with a missing current record wakes for teardown" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-1",
  "agents":{},
  "events":[{"eventId":"orphan-impl@7","agent":"orphan-impl","kind":"review-ready"}]
}]}
JSON
  printf 'orphan-impl@7\torphan-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/teardown-orphan"
  assert_monitor_ok "$SANDBOX/teardown-orphan"
  assert_exact_wake "$SANDBOX/teardown-orphan" 'WAKE teardown orphan-impl@7'
  awk -F '\t' \
    '$1 == "orphan-impl@7" && $5 == 1 && $6 == "teardown" { found = 1 }
     END { exit !found }' "$PENDING_FILE"
}

@test "auditable teardown resolution acknowledges the exact pending event" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"hold",
  "agents":{"impl":{"name":"orphan-impl","role":"impl","dispatchState":"captured"}},
  "events":[{
    "eventId":"orphan-impl@7",
    "agent":"orphan-impl",
    "kind":"review-ready",
    "teardownResolvedAt":"2026-09-04T00:00:00Z"
  }]
}]}
JSON
  printf 'orphan-impl@7\torphan-impl\tcaptured\t1\t1\tteardown\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/teardown-resolved"
  assert_monitor_ok "$SANDBOX/teardown-resolved"
  assert_silent "$SANDBOX/teardown-resolved"
  pending_absent 'orphan-impl@7'
  swept_contains 'orphan-impl@7'

  capture_monitor "$SANDBOX/teardown-resolved-stays-closed"
  assert_monitor_ok "$SANDBOX/teardown-resolved-stays-closed"
  assert_silent "$SANDBOX/teardown-resolved-stays-closed"
  pending_absent 'orphan-impl@7'
}

@test "explicit invalid-output resolution acknowledges the exact pending event" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"hold",
  "agents":{"review":{"name":"bad-review","role":"review","dispatchState":"resolved","captureEventId":"bad-review@9"}},
  "events":[{
    "eventId":"bad-review@9",
    "agent":"bad-review",
    "kind":"resolved-invalid-output",
    "capturePath":"/tmp/bad-review.txt"
  }]
}]}
JSON
  printf 'bad-review@9\tbad-review\tdone\t1\t1\tverdict\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/invalid-output-resolved"
  assert_monitor_ok "$SANDBOX/invalid-output-resolved"
  assert_silent "$SANDBOX/invalid-output-resolved"
  pending_absent 'bad-review@9'
  swept_contains 'bad-review@9'
}

@test "fresh capture stays quiet until the teardown grace expires" {
  local captured_at stale_at
  write_quiet_inventory
  captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  stale_at='2000-01-01T00:00:00Z'
  cat > "$FLEET_FILE" <<JSON
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-1",
  "agents":{"impl":{"name":"ticket-impl","role":"impl","dispatchState":"captured","capturedAt":"$captured_at"}},
  "events":[{"eventId":"ticket-impl@7","agent":"ticket-impl","kind":"review-ready"}]
}]}
JSON
  printf 'ticket-impl@7\tticket-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"

  capture_monitor "$SANDBOX/teardown-fresh"
  assert_monitor_ok "$SANDBOX/teardown-fresh"
  assert_silent "$SANDBOX/teardown-fresh"
  [ "$(prompt_count)" -eq 0 ]
  assert_pending_not_swept 'ticket-impl@7'
  run ! grep -Fqx 'teardown:ticket-impl' "$STATE_DIR/fleet-monitor.delivery-failures"

  python3 - "$FLEET_FILE" "$stale_at" <<'PYTHON'
import json
import sys

path, captured_at = sys.argv[1:]
with open(path) as fh:
    config = json.load(fh)
config["streams"][0]["agents"]["impl"]["capturedAt"] = captured_at
with open(path, "w") as fh:
    json.dump(config, fh)
PYTHON
  capture_monitor "$SANDBOX/teardown-stale"
  assert_monitor_ok "$SANDBOX/teardown-stale"
  assert_exact_wake "$SANDBOX/teardown-stale" 'WAKE teardown ticket-impl@7'
  [ "$(prompt_count)" -eq 0 ]
  assert_pending_not_swept 'ticket-impl@7'

  capture_monitor "$SANDBOX/teardown-before-retry"
  assert_monitor_ok "$SANDBOX/teardown-before-retry"
  assert_silent "$SANDBOX/teardown-before-retry"

  awk -F '\t' -v OFS='\t' '{$4 = 1; print}' "$PENDING_FILE" \
    > "$PENDING_FILE.tmp"
  mv "$PENDING_FILE.tmp" "$PENDING_FILE"
  export FLEET_ACK_TIMEOUT_SECONDS=1
  capture_monitor "$SANDBOX/teardown-retry"
  assert_monitor_ok "$SANDBOX/teardown-retry"
  assert_exact_wake "$SANDBOX/teardown-retry" 'WAKE teardown ticket-impl@7'
  awk -F '\t' \
    '$1 == "ticket-impl@7" && $5 == 2 && $6 == "teardown" { found = 1 }
     END { exit !found }' "$PENDING_FILE"
}

@test "closure between acknowledgement reads cannot emit a teardown wake" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"T1",
  "phase":"review-1",
  "agents":{"impl":{
    "name":"ticket-impl",
    "role":"impl",
    "dispatchState":"captured",
    "captureEventId":"ticket-impl@7",
    "capturedAt":"2026-01-01T00:00:00Z"
  }},
  "events":[{
    "eventId":"ticket-impl@7",
    "agent":"ticket-impl",
    "kind":"review-ready",
    "at":"2026-01-01T00:00:00Z"
  }]
}]}
JSON
  printf 'ticket-impl@7\tticket-impl\tdone\t1\t1\tcoordinator\n' > "$PENDING_FILE"
  export PYTHON_CLOSE_AFTER_ACK=1

  capture_monitor "$SANDBOX/close-race"

  assert_monitor_ok "$SANDBOX/close-race"
  assert_silent "$SANDBOX/close-race"
  assert_pending_not_swept 'ticket-impl@7'
  grep -Fq '"closedAt": "2026-09-04T00:00:00Z"' "$FLEET_FILE"

  export PYTHON_CLOSE_AFTER_ACK=0
  capture_monitor "$SANDBOX/close-race-next-poll"
  assert_monitor_ok "$SANDBOX/close-race-next-poll"
  assert_silent "$SANDBOX/close-race-next-poll"
  pending_absent 'ticket-impl@7'
  swept_contains 'ticket-impl@7'
}

@test "malformed event shape keeps the config alarm deduplicated" {
  write_quiet_inventory
  printf '{"workspace":"w1","streams":[{"agents":{},"events":[null]}]}\n' > "$FLEET_FILE"

  capture_monitor "$SANDBOX/event-shape-1"
  assert_monitor_ok "$SANDBOX/event-shape-1"
  assert_exact_wake "$SANDBOX/event-shape-1" 'WAKE state fleet.json'

  capture_monitor "$SANDBOX/event-shape-2"
  assert_monitor_ok "$SANDBOX/event-shape-2"
  assert_silent "$SANDBOX/event-shape-2"
}

@test "duplicate event IDs keep the config alarm deduplicated and rearm after recovery" {
  write_quiet_inventory
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[
  {"ticket":"T1","agents":{},"events":[{"eventId":"duplicate@7","agent":"one"}]},
  {"ticket":"T2","agents":{},"events":[{"eventId":"duplicate@7","agent":"two"}]}
]}
JSON

  capture_monitor "$SANDBOX/event-id-duplicate-1"
  assert_monitor_ok "$SANDBOX/event-id-duplicate-1"
  assert_exact_wake "$SANDBOX/event-id-duplicate-1" 'WAKE state fleet.json'

  capture_monitor "$SANDBOX/event-id-duplicate-2"
  assert_monitor_ok "$SANDBOX/event-id-duplicate-2"
  assert_silent "$SANDBOX/event-id-duplicate-2"

  write_empty_fleet
  capture_monitor "$SANDBOX/event-id-recovered"
  assert_monitor_ok "$SANDBOX/event-id-recovered"
  assert_silent "$SANDBOX/event-id-recovered"

  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[
  {"ticket":"T1","agents":{},"events":[{"eventId":"duplicate@7","agent":"one"}]},
  {"ticket":"T2","agents":{},"events":[{"eventId":"duplicate@7","agent":"two"}]}
]}
JSON
  capture_monitor "$SANDBOX/event-id-duplicate-rearmed"
  assert_monitor_ok "$SANDBOX/event-id-duplicate-rearmed"
  assert_exact_wake "$SANDBOX/event-id-duplicate-rearmed" 'WAKE state fleet.json'
}

@test "successful logging rearms its state alarm" {
  write_empty_fleet
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"unregistered","agent_status":"done","state_change_seq":1,"terminal_title":""}
]}}
JSON
  : > "$LOG_FILE"
  chmod 400 "$LOG_FILE"

  capture_monitor "$SANDBOX/log-fail-1"
  assert_monitor_ok "$SANDBOX/log-fail-1"
  assert_exact_wake "$SANDBOX/log-fail-1" 'WAKE state log'

  chmod 600 "$LOG_FILE"
  capture_monitor "$SANDBOX/log-recovered"
  assert_monitor_ok "$SANDBOX/log-recovered"
  assert_silent "$SANDBOX/log-recovered"
  run ! grep -Fqx 'state:log' "$STATE_DIR/fleet-monitor.delivery-failures"

  chmod 400 "$LOG_FILE"
  capture_monitor "$SANDBOX/log-fail-2"
  chmod 600 "$LOG_FILE"
  assert_monitor_ok "$SANDBOX/log-fail-2"
  assert_exact_wake "$SANDBOX/log-fail-2" 'WAKE state log'
}

@test "fault ledger clear failure emits one nonrecursive state wake" {
  write_empty_fleet
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3,"terminal_title":""},
  {"name":"unregistered","agent_status":"done","state_change_seq":1,"terminal_title":""}
]}}
JSON
  printf 'state:log\n' > "$STATE_DIR/fleet-monitor.delivery-failures"
  : > "$LOG_FILE"
  export MV_FAIL_DEST="$STATE_DIR/fleet-monitor.delivery-failures"
  export FLEET_POLL_SECONDS=1

  start_monitor "$SANDBOX/fault-ledger"
  wait_until 'fault ledger state wake' file_contains_line \
    "$SANDBOX/fault-ledger.stdout" 'WAKE state failures'
  wait_until 'poll after fault ledger state wake' list_count_at_least 3
  stop_monitor

  assert_exact_wake "$SANDBOX/fault-ledger" 'WAKE state failures'
  grep -Fqx 'state:log' "$STATE_DIR/fleet-monitor.delivery-failures"
}

@test "fault ledger alarm rearms after a persistent-process recovery" {
  local failures="$STATE_DIR/fleet-monitor.delivery-failures"
  write_quiet_inventory
  write_empty_fleet
  export FLEET_POLL_SECONDS=1

  start_monitor "$SANDBOX/fault-rearm"
  wait_until 'initial healthy poll' list_count_at_least 1

  chmod 000 "$failures"
  wait_until 'first fault-ledger wake' file_line_count_at_least \
    "$SANDBOX/fault-rearm.stdout" 'WAKE state failures' 1
  wait_until 'deduplicated first outage' list_count_at_least 3
  [ "$(grep -Fxc 'WAKE state failures' "$SANDBOX/fault-rearm.stdout")" -eq 1 ]

  chmod 600 "$failures"
  wait_until 'fault-ledger recovery poll' list_count_at_least 4
  chmod 000 "$failures"
  wait_until 'second fault-ledger wake' file_line_count_at_least \
    "$SANDBOX/fault-rearm.stdout" 'WAKE state failures' 2
  wait_until 'deduplicated second outage' list_count_at_least 6
  chmod 600 "$failures"
  stop_monitor

  [ "$(grep -Fxc 'WAKE state failures' "$SANDBOX/fault-rearm.stdout")" -eq 2 ]
  [ ! -s "$SANDBOX/fault-rearm.stderr" ]
}

@test "seed read failure wakes once and rearms after recovery" {
  write_quiet_inventory
  write_empty_fleet
  export GIT_REV_PARSE_FAIL=1

  capture_monitor "$SANDBOX/seed-fail-1"
  assert_monitor_ok "$SANDBOX/seed-fail-1"
  assert_exact_wake "$SANDBOX/seed-fail-1" 'WAKE state seed'

  capture_monitor "$SANDBOX/seed-fail-2"
  assert_monitor_ok "$SANDBOX/seed-fail-2"
  assert_silent "$SANDBOX/seed-fail-2"

  export GIT_REV_PARSE_FAIL=0
  capture_monitor "$SANDBOX/seed-recovered"
  assert_monitor_ok "$SANDBOX/seed-recovered"
  assert_silent "$SANDBOX/seed-recovered"

  export GIT_REV_PARSE_FAIL=1
  capture_monitor "$SANDBOX/seed-fail-again"
  assert_monitor_ok "$SANDBOX/seed-fail-again"
  assert_exact_wake "$SANDBOX/seed-fail-again" 'WAKE state seed'
}

@test "repeated inventory failure wakes once per failure episode" {
  write_quiet_inventory
  write_empty_fleet
  export HERDR_LIST_MODE=fail

  capture_monitor "$SANDBOX/inventory-first"
  assert_monitor_ok "$SANDBOX/inventory-first"
  assert_exact_wake "$SANDBOX/inventory-first" 'WAKE inventory'

  capture_monitor "$SANDBOX/inventory-repeat"
  assert_monitor_ok "$SANDBOX/inventory-repeat"
  assert_silent "$SANDBOX/inventory-repeat"

  export HERDR_LIST_MODE=ok
  capture_monitor "$SANDBOX/inventory-recovered"
  assert_monitor_ok "$SANDBOX/inventory-recovered"
  assert_silent "$SANDBOX/inventory-recovered"

  export HERDR_LIST_MODE=fail
  capture_monitor "$SANDBOX/inventory-next-episode"
  assert_monitor_ok "$SANDBOX/inventory-next-episode"
  assert_exact_wake "$SANDBOX/inventory-next-episode" 'WAKE inventory'
}

@test "coordinator blocked on consecutive polls wakes once" {
  write_empty_fleet
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"blocked","state_change_seq":4,"terminal_title":""}
]}}
JSON

  export MONITOR_CONTINUOUS=1
  export FLEET_POLL_SECONDS=1
  invoke_monitor > "$SANDBOX/blocked.stdout" 2> "$SANDBOX/blocked.stderr" &
  MONITOR_PID=$!

  wait_until 'blocked coordinator wake' \
    file_contains_line "$SANDBOX/blocked.stdout" 'WAKE blocked coordinator'
  wait_until 'poll after blocked coordinator wake' list_count_at_least 3
  [ "$(grep -Fxc 'WAKE blocked coordinator' "$SANDBOX/blocked.stdout")" -eq 1 ]
  [ ! -s "$SANDBOX/blocked.stderr" ]
}

@test "missing coordinator wake is deduplicated and rearms after recovery" {
  write_empty_fleet
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"worker","agent_status":"working","state_change_seq":1,"terminal_title":""}
]}}
JSON

  capture_monitor "$SANDBOX/missing-1"
  assert_monitor_ok "$SANDBOX/missing-1"
  assert_exact_wake "$SANDBOX/missing-1" 'WAKE coordinator missing'

  capture_monitor "$SANDBOX/missing-2"
  assert_monitor_ok "$SANDBOX/missing-2"
  assert_silent "$SANDBOX/missing-2"

  write_quiet_inventory
  capture_monitor "$SANDBOX/recovered"
  assert_monitor_ok "$SANDBOX/recovered"
  assert_silent "$SANDBOX/recovered"

  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"worker","agent_status":"working","state_change_seq":2,"terminal_title":""}
]}}
JSON
  capture_monitor "$SANDBOX/missing-again"
  assert_monitor_ok "$SANDBOX/missing-again"
  assert_exact_wake "$SANDBOX/missing-again" 'WAKE coordinator missing'
}

@test "successful pending writes rearm their deduplicated state alarms" {
  write_settled_inventory
  write_unacknowledged_fleet
  printf '%s\n' \
    'queue:ticket-impl@7' \
    'state:ticket-impl@7' \
    'state:pending' > "$STATE_DIR/fleet-monitor.delivery-failures"

  capture_monitor "$SANDBOX/rearmed-state"

  assert_monitor_ok "$SANDBOX/rearmed-state"
  assert_silent "$SANDBOX/rearmed-state"
  run ! grep -Fqx 'queue:ticket-impl@7' "$STATE_DIR/fleet-monitor.delivery-failures"
  run ! grep -Fqx 'state:ticket-impl@7' "$STATE_DIR/fleet-monitor.delivery-failures"
  run ! grep -Fqx 'state:pending' "$STATE_DIR/fleet-monitor.delivery-failures"
}
