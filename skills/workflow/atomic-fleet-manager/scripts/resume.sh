#!/usr/bin/env bash
# Resume an issue's interrupted goal-select run under the same run id, so the
# stages it already finished are reused instead of repeated by a new run.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: resume.sh --issue ID [options]

  --issue ID          Tracker issue identifier (TUS-58); also the name of its
                      terminal (fleet.name)
  --run RUN_ID        Run to resume (default: the issue's most recent run)
  --message TEXT      News for the orchestrator, delivered with the resume
  --fresh             Resume from a new Atomic process in a new terminal, for
                      a dead session or a stale provider login. Close the
                      old terminal first (hc kill, hc rm).
  --cwd DIR           Working directory for --fresh (default: the run's own)
  --agent-dir DIR     Atomic agent directory for --fresh, when the run was
                      launched under a second account (launch.sh --agent-dir)
  --terminal T        The run's terminal (default: the one named for the
                      issue, found through status.sh)
  --space ID          The fleet's GUI space (default: the caller's own;
                      --workspace is the old name). Needed through hc exec.
  --max-load N        Refuse above this 1-minute load average (default 12)
  --timeout SECONDS   Wait this long for the run to go live (default 120)
  --status            Print the run's state and exit; resume nothing

Prints `RESUMED: <issue> <run id> <latest stage>` once the run is live.
Exits 1 with the reason when the run cannot be resumed or ends blocked.
USAGE
}

issue="" run="" message="" fresh="" cwd="" terminal="" max_load=12 timeout=300 status_only="" agent_dir=""
workspace=""
database="${ATOMIC_WORKFLOW_DATABASE_URL:-postgresql://postgres:atomic@127.0.0.1:5439/atomic_workflows_dbos_sys}"
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    --fresh) fresh=1; shift ;;
    --cwd) cwd="$2"; shift 2 ;;
    --agent-dir) agent_dir="$2"; shift 2 ;;
    --space|--workspace) workspace="$2"; shift 2 ;;
    --terminal) terminal="$2"; shift 2 ;;
    --max-load) max_load="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --status) status_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "Error: $1" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"

[ -n "$issue" ] || fail "--issue is required."
command -v psql >/dev/null || fail "psql is not installed; it reads the run's state from Atomic's workflow database."

sql() { psql "$database" -X -At -F $'\t' -v ON_ERROR_STOP=1 -c "$1"; }
case "$issue$run" in *"'"*) fail "the issue and run id may not contain a quote." ;; esac

# The newest metadata checkpoint of a run holds its state.
state_of() {
  sql "SELECT md->>'status', coalesce(md->>'resumable', 'true'),
              extract(epoch FROM now())::bigint - (md->>'updatedAt')::bigint / 1000,
              coalesce(md->>'invocationCwd', ''), coalesce(left(md->>'error', 200), '')
       FROM (SELECT (output::jsonb)->'json'->'metadata' AS md FROM dbos.workflow_status
             WHERE workflow_uuid LIKE '$1' || ':checkpoint:\_\_atomic\_metadata:%'
             ORDER BY created_at DESC LIMIT 1) latest"
}
latest_stage() {
  sql "SELECT (output::jsonb)->'json'->>'name' FROM dbos.workflow_status
       WHERE workflow_uuid LIKE '$1' || ':checkpoint:stage-%' ORDER BY created_at DESC LIMIT 1"
}

if [ -z "$run" ]; then
  run="$(sql "SELECT run_id FROM (
            SELECT DISTINCT ON (run_id) split_part(workflow_uuid, ':checkpoint:', 1) AS run_id,
                   (output::jsonb)->'json'->'metadata' AS md, created_at
            FROM dbos.workflow_status
            WHERE workflow_uuid LIKE '%:checkpoint:\_\_atomic\_metadata:%'
              AND created_at > (extract(epoch FROM now() - interval '7 days') * 1000)::bigint
            ORDER BY run_id, created_at DESC) runs
          WHERE md->'inputs'->>'tracker_issue' = '$issue'
          ORDER BY created_at DESC LIMIT 1")"
  [ -n "$run" ] || fail "no run for $issue in the last 7 days; pass --run."
fi

IFS=$'\t' read -r status resumable idle run_cwd error <<<"$(state_of "$run")"
[ -n "${status:-}" ] || fail "run $run has no recorded state."
# A run still marked running that stopped writing has lost its process.
if [ "$status" = running ] && [ "$idle" -gt 120 ]; then status=crashed; fi

if [ -n "$status_only" ]; then
  printf 'issue=%s\nrun=%s\nstatus=%s\nresumable=%s\nidle_seconds=%s\nlatest_stage=%s\ncwd=%s\nerror=%s\n' \
    "$issue" "$run" "$status" "$resumable" "$idle" "$(latest_stage "$run")" "$run_cwd" "$error"
  exit 0
fi

case "$status" in
  running) fail "run $run is live (last write ${idle}s ago); nothing to resume." ;;
  completed|cancelled|killed) fail "run $run is $status and cannot be resumed." ;;
esac
[ "$resumable" != false ] || fail "run $run is marked not resumable: $error"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$here/fleet-hc.sh"
fleet_need_hc
load="$(fleet_load)"
awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(l < m) }' ||
  fail "the 1-minute load average is $load (limit $max_load); a resume now would die the same way. Wait for it to fall."

[ -n "$workspace" ] || workspace="$(fleet_space)"
[ -n "$workspace" ] || fail "no GUI space: run inside an hc terminal of the fleet or pass --space."

pane_state() { fleet_state "$1"; }

if [ -n "$fresh" ]; then
  # Atomic lets another process take a run over only after its owner has
  # been silent for two minutes.
  [ "$idle" -ge 120 ] || fail "run $run was last written ${idle}s ago; a fresh process may take it over after 120s. Quit the old session and wait."
  dir="${cwd:-$run_cwd}"
  [ -d "$dir" ] || fail "the run's working directory '$dir' is gone; pass --cwd."
  run_env=(env)
  if [ -n "$agent_dir" ]; then
    agent_dir="${agent_dir/#\~/$HOME}"
    [ -f "$agent_dir/auth.json" ] || fail "--agent-dir '$agent_dir' has no auth.json."
    run_env=(env -u ANTHROPIC_API_KEY "ATOMIC_CODING_AGENT_DIR=$agent_dir")
  fi
  pane="$(fleet_open "$issue" harness "$dir" --space "$workspace" -- "${run_env[@]}" atomic)" ||
    fail "could not open a terminal for $issue."
  waited=0
  until case "$(pane_state "$pane")" in "atomic idle"|"atomic done") true ;; *) false ;; esac; do
    [ "$waited" -lt 60 ] || fail "Atomic was not ready in terminal $pane after 60s; the terminal is left open."
    sleep 2; waited=$((waited + 2))
  done
  fleet_name_tab "$pane" "$issue"
  # A process other than the run's owner may resume only the whole run.
  text="/workflow resume $run"
else
  pane="$terminal"
  [ -n "$pane" ] || pane="$("$here/status.sh" "$workspace" | awk -F'\t' -v l="$issue" '$1 == l { print $2 }' | tail -1)"
  [ -n "$pane" ] || fail "no terminal named $issue; use --fresh to resume from a new Atomic process."
  case "$(pane_state "$pane")" in
    "atomic working") fail "the Atomic session in $pane is busy; read it (hc read $pane) before resuming." ;;
    atomic*) ;;
    *) fail "terminal $pane has no Atomic session; use --fresh." ;;
  esac
  # Plain language is the reliable form in the owning session: the slash
  # command reads the word after the run id as a stage name.
  text="Fleet manager: resume workflow run $run where it stopped. Do not start a new run."
fi
if [ -n "$message" ]; then
  # A message cannot ride on the slash command without being read as a stage.
  text="Fleet manager: resume workflow run $run where it stopped, as a whole run with no stage selector. Do not start a new run. News for the orchestrator: $message"
fi

# Since Atomic 0.9.27 a stage that fails on infrastructure leaves its run held
# as paused inside the owning session, which refuses a resume as "already
# running in this session". Count those refusals so a new one can be told
# from an old one still on the screen.
refusals() {
  fleet_read "$pane" 200 |
    tr -d '\n│' | tr -s ' ' | { grep -o "already running in this session" || true; } | wc -l | tr -d ' '
}
submit() { fleet_send "$pane" "$1"; }

# Since Atomic 0.9.28 a resume opens the run's graph in the terminal. The
# fleet's scripts read the chat view, where the run's panel is, so go back.
leave_graph() {
  if fleet_read "$pane" | tail -12 | grep -q "return to main chat"; then
    hc keys "$pane" ctrl+x >/dev/null 2>&1 || true
  fi
}

refused_before="$(refusals)"
requit=""
# A run that stopped as blocked (a stage that failed while shutting down, for
# one) still reads as blocked for the first moments after the resume is sent.
# Only a run that is blocked again after this grace period ended blocked.
IFS=$'\t' read -r status_before _ <<<"$(state_of "$run")"
blocked_grace=90
submit "$text"

waited=0
while :; do
  sleep 5; waited=$((waited + 5))
  if [ -z "$fresh" ] && [ -z "$requit" ] && [ "$(refusals)" -gt "$refused_before" ]; then
    # Quitting the held run keeps it resumable; then the resume is accepted.
    requit=1
    submit "/workflow quit $run"
    quit_waited=0
    until fleet_read "$pane" 60 | grep -q "quit and can be resumed"; do
      sleep 3; quit_waited=$((quit_waited + 3))
      [ "$quit_waited" -lt 60 ] || fail "run $run is held in $pane and did not quit; read the pane."
    done
    submit "$text"
    waited=0
    continue
  fi
  IFS=$'\t' read -r status resumable idle run_cwd error <<<"$(state_of "$run")"
  case "$status" in
    running) [ "$idle" -gt 30 ] || break ;;
    blocked)
      if [ "$status_before" != blocked ] || [ "$waited" -ge "$blocked_grace" ]; then
        fail "run $run ended blocked on resume: ${error:-read the pane}. The goal ledger may hold a decision that closes it; read it before starting a new run."
      fi ;;
    completed) echo "COMPLETED: $issue $run"; exit 0 ;;
  esac
  if [ "$waited" -ge "$timeout" ]; then
    leave_graph
    fail "run $run is still '$status' ${timeout}s after the resume was sent to $pane; read the pane."
  fi
done
leave_graph

echo "RESUMED: $issue $run $(latest_stage "$run")"
echo "terminal=$pane"
echo "pane=$pane"
