#!/usr/bin/env bash
# Watch the CI runs for one pushed commit until they conclude. Arm it with the
# pushed SHA immediately after every push: a push with no live watcher is a
# blind deploy.
#
# Exits after printing CI-GREEN, CI-RED, CI-WATCH-TIMEOUT, or
# CI-WATCH-PARSE-FAILURE, so the orchestrator is woken exactly once per push.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$SCRIPT_DIR/fleet-env.sh"

usage() {
  cat <<'EOF'
Usage: ci-watch.sh <pushed-sha> [--help]

Required binding: FLEET_SEED.
Runtime state defaults to <seed>/temp/fleet/.
Optional: FLEET_CI_POLLS, FLEET_CI_POLL_SECONDS, FLEET_CI_RETRIGGER_WORKFLOW,
FLEET_CI_RETRIGGER_REF, FLEET_ENV.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac

fleet_env_load || exit 2
fleet_env_require FLEET_SEED FLEET_STATE_DIR || exit 2

# `gh run list --commit` matches on the FULL head SHA; a short SHA silently
# matches nothing and the watcher reports a green that never ran.
if ! sha="$(git -C "$FLEET_SEED" rev-parse "$1" 2>/dev/null)"; then
  echo "ci-watch: '$1' is not a revision in $FLEET_SEED" >&2
  exit 2
fi

echo "$sha" > "$FLEET_PUSH_MARKER"
cd "$FLEET_SEED" || exit 2
retriggered=""

for poll in $(seq 1 "$FLEET_CI_POLLS"); do
  date +%s > "$FLEET_CI_HEARTBEAT"
  line="$(gh run list --commit "$sha" --json name,status,conclusion --limit 20 2>&1 | python3 -c "
import json, sys
try:
    runs = json.load(sys.stdin)
    print(';'.join(f\"{r['name']}|{r['status']}|{r.get('conclusion') or ''}\" for r in runs)
          or 'NO-RUNS-YET')
except Exception as exc:
    print(f'PARSE-ERROR:{exc}')")"
  echo "--- $(date +%H:%M:%S) $line"

  case "$line" in
    PARSE-ERROR*)
      echo CI-WATCH-PARSE-FAILURE
      exit 1
      ;;
  esac

  # Provenance: a forge dropped a push event once and no run was ever created
  # for a landed push, which looked like an eternally queued pipeline. If no
  # run appears within a few polls of arming, trigger the configured workflow
  # explicitly, once, and only when the operator configured one.
  if [ "$line" = NO-RUNS-YET ] && [ "$poll" -ge 3 ] && [ -z "$retriggered" ] &&
    [ -n "${FLEET_CI_RETRIGGER_WORKFLOW:-}" ]; then
    if gh workflow run "$FLEET_CI_RETRIGGER_WORKFLOW" \
      --ref "${FLEET_CI_RETRIGGER_REF:-HEAD}" > /dev/null 2>&1; then
      retriggered=1
      echo "--- $(date +%H:%M:%S) no runs yet: re-triggered $FLEET_CI_RETRIGGER_WORKFLOW"
    fi
  fi

  # Any concluded failure exits immediately. Waiting for still-running
  # siblings only delays a red the orchestrator must act on.
  if echo "$line" | grep -q '|failure\|cancelled\|timed_out'; then
    echo "CI-DONE $line"
    echo CI-RED
    rm -f "$FLEET_PUSH_MARKER"
    exit 0
  fi

  if [ "$line" != NO-RUNS-YET ] &&
    ! echo "$line" | grep -q 'in_progress\|queued\|pending\|requested\|waiting'; then
    echo "CI-DONE $line"
    echo CI-GREEN
    rm -f "$FLEET_PUSH_MARKER"
    exit 0
  fi

  sleep "$FLEET_CI_POLL_SECONDS"
done

echo CI-WATCH-TIMEOUT
