#!/usr/bin/env bash
# The landing gate: every check a train must pass, run in one checkout.
#
#   .atomic/fleet/gate.sh <checkout path>
#
# Prints one line per step (TYPECHECK_OK, LINT_FAILED, ...) and ends with
# GATE_OK only when every step passed. Logs go to $GATE_LOG_DIR (default
# /tmp/casefilecrafter-gate/<checkout name>-<time>/). The e2e step runs
# through e2e-check.sh, which serializes on the suite's fixed ports; the
# component suite uses two workers. At most GATE_SLOTS gates run at a time
# (GATE_WAITING while the slots are full). A harness runs this as its last step
# and reports the last line; the fleet manager runs it on every train.
set -uo pipefail

checkout="${1:-}"
# shellcheck disable=SC2015  # Either test failing means bad usage.
[ -n "$checkout" ] && [ -d "$checkout" ] || { echo "usage: gate.sh <checkout path>" >&2; echo "GATE_FAILED"; exit 2; }
checkout="$(cd "$checkout" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
name="$(basename "$checkout")"
logs="${GATE_LOG_DIR:-${TMPDIR:-/tmp}/casefilecrafter-gate/$name-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$logs"

# A fixed number of gates at a time on this machine (GATE_SLOTS, default 3;
# it was 2 until the end-to-end step could run three at once and Atomic's
# database probe learned to retry).
# Several harnesses reach their last step together; four gates side by side
# took an 18-core machine to a load of 21, where Atomic's one-second database
# probe failed a run, while one gate leaves it more than 80% idle. The
# end-to-end step has three slots of its own (e2e-check.sh). A slot's
# holder writes its pid in it; a dead holder's slot is taken over.
gate_lock_base="${GATE_LOCK:-/tmp/casefilecrafter-gate.lock}"
gate_slots="${GATE_SLOTS:-3}"
gate_waited=0
# A train sets GATE_PRIORITY: landing frees a slot and feeds review, so a
# waiting train takes the next slot ahead of a harness's own final run.
gate_priority="${GATE_PRIORITY:-}"
priority_dir="$gate_lock_base.priority"
if [ -n "$gate_priority" ]; then mkdir -p "$priority_dir" && : > "$priority_dir/$$"; fi
train_waiting() {
  local marker
  for marker in "$priority_dir"/*; do
    [ -e "$marker" ] || continue
    if kill -0 "$(basename "$marker")" 2>/dev/null; then return 0; fi
    rm -f "$marker"
  done
  return 1
}
# Slot 1 is the bare path, slot N is the path with ".N".
slot_path() { if [ "$1" = 1 ]; then echo "$gate_lock_base"; else echo "$gate_lock_base.$1"; fi; }
take_slot() {
  local n path holder
  for n in $(seq 1 "$gate_slots"); do
    path="$(slot_path "$n")"
    if mkdir "$path" 2>/dev/null; then gate_lock="$path"; return 0; fi
    holder="$(cat "$path/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$path"; fi
    if [ -z "$holder" ] && [ -n "$(find "$path" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rm -rf "$path"; fi
  done
  return 1
}
gate_lock=""
until { [ -n "$gate_priority" ] || ! train_waiting; } && take_slot; do
  [ $((gate_waited % 300)) = 0 ] && echo "GATE_WAITING: all $gate_slots gate slots are taken ($(cat "$gate_lock_base"*/checkout 2>/dev/null | tr '\n' ' ')); this one starts when one ends"
  sleep 10
  gate_waited=$((gate_waited + 10))
done
[ -z "$gate_priority" ] || rm -f "$priority_dir/$$"
echo $$ > "$gate_lock/pid"
echo "$name" > "$gate_lock/checkout"
trap 'rm -rf "$gate_lock"' EXIT

# The fleet's load rule holds for every gate: do not start the suites on a
# machine that is already saturated. After 15 minutes of waiting, go anyway.
gate_max_load="${GATE_MAX_LOAD:-12}"
load_waited=0
while awk -v load="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')" -v max="$gate_max_load" 'BEGIN { exit !(load >= max) }' &&
  [ "$load_waited" -lt 900 ]; do
  [ $((load_waited % 300)) = 0 ] && echo "GATE_WAITING: the machine load is at or above $gate_max_load; this gate starts when it falls"
  sleep 15
  load_waited=$((load_waited + 15))
done
echo "gate: $checkout at $(git -C "$checkout" rev-parse --short HEAD 2>/dev/null); logs in $logs"

failed=0
run() { # LABEL command...
  local label="$1"
  shift
  if (cd "$checkout" && "$@") >"$logs/$label.log" 2>&1; then
    echo "${label}_OK"
  else
    echo "${label}_FAILED"
    sed 's/\x1b\[[0-9;]*m//g' "$logs/$label.log" | grep -E "error TS|FAIL|ERR_|ReferenceError|Error:|✖|×" | cut -c1-200 | sort -u | head -10
    failed=1
    return 1
  fi
}

run INSTALL pnpm install &&
run DB pnpm db:test:reset &&
run TYPECHECK pnpm typecheck &&
run LINT pnpm lint &&
run UNIT pnpm test:unit &&
run INTEGRATION pnpm test:integration
for log in UNIT INTEGRATION; do
  [ -f "$logs/$log.log" ] && sed 's/\x1b\[[0-9;]*m//g' "$logs/$log.log" | grep -E "(api|web|contracts).*Tests " | cut -c1-100
done
[ "$failed" = 0 ] || { echo "GATE_FAILED"; exit 1; }

e2e_line="$("$here/e2e-check.sh" "$checkout" 2>"$logs/e2e.err" | tail -1)"
echo "$e2e_line"
e2e_failed="$(printf '%s' "$e2e_line" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
e2e_flaky="$(printf '%s' "$e2e_line" | sed -n 's/.*flaky=\([0-9]*\).*/\1/p')"
e2e_passed="$(printf '%s' "$e2e_line" | sed -n 's/.*passed=\([0-9]*\).*/\1/p')"
if [ "${e2e_passed:-0}" -gt 0 ] && [ "${e2e_failed:-1}" = 0 ] && [ "${e2e_flaky:-1}" = 0 ]; then
  echo "E2E_OK"
else
  echo "E2E_FAILED"
  grep -E "^ +[0-9]+\) \[" "$logs/e2e.err" | cut -c1-200 | head -6
  echo "GATE_FAILED"; exit 1
fi

# A harness's own gate skips the component suite when its branch changes no
# file the suite can see: nothing under apps/web, apps/e2e, packages or db,
# and no root manifest. The suite drives web components against stubs, takes
# ten minutes and holds the e2e lock, and with many small API units running
# their gates queued for hours (2026-10-09). The landing train always runs
# it: the staging clone is never skipped, and GATE_FULL=1 forces it anywhere.
if [ "${GATE_FULL:-}" != 1 ] && [ "${name##*.}" != train ]; then
  base="$(git -C "$checkout" merge-base HEAD main 2>/dev/null || true)"
  if [ -n "$base" ]; then
    changed="$( { git -C "$checkout" diff --name-only "$base" HEAD; git -C "$checkout" status --porcelain | cut -c4-; } 2>/dev/null | sort -u)"
    if [ -n "$changed" ] && ! printf '%s\n' "$changed" | grep -Eq '^(apps/web/|apps/e2e/|packages/|db/|package\.json$|pnpm-lock\.yaml$|pnpm-workspace\.yaml$|turbo\.json$|biome\.json$|\.github/)'; then
      echo "COMPONENTS_SKIPPED: this branch changes no web, e2e, package or database file; the landing train runs the component suite"
      echo "GATE_OK"
      exit 0
    fi
  fi
fi

# A component spec with an unstubbed read reaches whatever serves ports 3000
# and 4000. Chromium resolves localhost to 127.0.0.1, so while another
# checkout's e2e stage is up, that is its API: a block of Chromium-only
# failures in specs that touch the API (seen 2026-10-09, 26 failures on a
# change to docs and hooks). Hold the e2e lock for the component suite, so
# no e2e servers are up beside it. Same directory and protocol as
# e2e-check.sh.
e2e_lock="${TMPDIR:-/tmp}/casefilecrafter-e2e-check.lock"
component_lock_deadline=$(($(date +%s) + 3600))
component_lock_waited=0
while ! mkdir "$e2e_lock" 2>/dev/null; do
  lock_holder="$(cat "$e2e_lock/pid" 2>/dev/null)"
  if [ -n "$lock_holder" ] && ! kill -0 "$lock_holder" 2>/dev/null; then
    rm -rf "$e2e_lock"
    continue
  fi
  if [ "$(date +%s)" -ge "$component_lock_deadline" ]; then
    echo "COMPONENTS_FAILED: pid $lock_holder held the e2e lock for an hour"
    echo "GATE_FAILED"; exit 1
  fi
  [ $((component_lock_waited % 300)) = 0 ] && echo "COMPONENTS_WAITING: another checkout's e2e stage or component suite is running (pid $lock_holder)"
  sleep 5
  component_lock_waited=$((component_lock_waited + 5))
done
echo $$ >"$e2e_lock/pid"
trap 'rm -rf "$gate_lock" "$e2e_lock"' EXIT
(cd "$checkout" && pnpm --filter @casefilecrafter/e2e test:components --workers 2) >"$logs/components.log" 2>&1
components_exit=$?
rm -rf "$e2e_lock"
trap 'rm -rf "$gate_lock"' EXIT
sed 's/\x1b\[[0-9;]*m//g' "$logs/components.log" | grep -E "^ +[0-9]+ (passed|failed|flaky|skipped)" | tr '\n' ' '; echo
# KNOWN_COMPONENT_FAILURES: a regex of failures already on the seed tip and
# being fixed elsewhere; any failure outside it still fails the gate.
unknown="$(sed 's/\x1b\[[0-9;]*m//g' "$logs/components.log" | grep -E "^ +[0-9]+\) \[" | grep -vcE "${KNOWN_COMPONENT_FAILURES:-^$}")"
ran="$(sed 's/\x1b\[[0-9;]*m//g' "$logs/components.log" | grep -cE "^ +[0-9]+ passed")"
if [ "$components_exit" = 0 ]; then
  echo "COMPONENTS_OK"
elif [ -n "${KNOWN_COMPONENT_FAILURES:-}" ] && [ "$unknown" = 0 ] && [ "$ran" -gt 0 ]; then
  echo "COMPONENTS_OK_KNOWN_FAILURES_ONLY"
else
  echo "COMPONENTS_FAILED"
  sed 's/\x1b\[[0-9;]*m//g' "$logs/components.log" | grep -E "^ +[0-9]+\) \[chromium\]" | sort -u | cut -c1-180 | head -8
  echo "GATE_FAILED"; exit 1
fi
echo "GATE_OK"
