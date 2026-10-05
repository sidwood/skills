#!/usr/bin/env bash
# Start one Atomic goal-select harness in its own Herdr tab and confirm it was
# dispatched. Prints one "key=value" line per fact for the caller to read.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: launch.sh --issue ID --policy NAME_OR_PATH [options]

  --issue ID           Tracker issue identifier, also the tab label (TUS-150)
  --policy NAME|PATH   Preset name (opus-astra) or a path to a policy file
  --tracker NAME       linear (default), jira or none
  --checkout DIR       Existing branch clone to continue in (default: auto,
                       which makes a new clone from the seed)
  --objective TEXT     Text added to the issue as this run's objective
  --seed DIR           Seed checkout to launch from (default: current directory)
  --workspace ID       Herdr workspace (default: $HERDR_WORKSPACE_ID)
  --workflow NAME      Workflow to run (default: goal-select)
  --resolve-only       Preview models and clone path; runs no Goal stage
  --max-workers N      Test workers each suite may use in this harness
                       (default: 4; sets VITEST_MAX_WORKERS in the tab and
                       adds a note to the objective for other runners)
  --timeout SECONDS    Wait for Atomic and for dispatch (default: 60 each)
USAGE
}

issue="" policy="" tracker="linear" checkout="" objective="" seed="$PWD"
workspace="${HERDR_WORKSPACE_ID:-}" workflow="goal-select" resolve_only=""
timeout=60 max_workers=4
policy_dir="${ATOMIC_POLICY_DIR:-$HOME/.config/atomic/goal-select-models}"

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --policy) policy="$2"; shift 2 ;;
    --tracker) tracker="$2"; shift 2 ;;
    --checkout) checkout="$2"; shift 2 ;;
    --objective) objective="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --workflow) workflow="$2"; shift 2 ;;
    --resolve-only) resolve_only=1; shift ;;
    --max-workers) max_workers="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "Error: $1" >&2; exit 1; }

[ "${HERDR_ENV:-}" = 1 ] || fail "not running inside a Herdr pane."
[ -n "$issue" ] || fail "--issue is required."
[ -n "$policy" ] || fail "--policy is required."
[ -n "$workspace" ] || fail "no Herdr workspace; pass --workspace."
command -v atomic >/dev/null || fail "atomic is not on PATH."

case "$policy" in
  */*|*.json) policy_path="$policy" ;;
  *) policy_path="$policy_dir/$policy.json" ;;
esac
[ -f "$policy_path" ] || fail "policy file '$policy_path' does not exist."

# Prime directive: a model line never reviews its own work.
same_line="$(python3 - "$policy_path" <<'PY'
import json, re, sys
text = re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[1]).read())
try:
    policy = json.loads(text)
except ValueError:
    sys.exit(0)  # JSONC this check cannot parse; the workflow validates it
line = lambda m: (m or "").split("/")[-1].split(":")[0]
writer = line(policy.get("writer_model") or policy.get("orchestrator_model"))
reviewers = {line(v) for k, v in policy.items() if k.endswith("reviewer_model") and v}
if writer and writer in reviewers:
    print(writer)
PY
)"
[ -z "$same_line" ] || fail "policy '$policy_path' has '$same_line' as both writer and reviewer; a model line must not review itself."

seed="$(cd "$seed" && pwd)"
git -C "$seed" rev-parse --git-dir >/dev/null 2>&1 || fail "'$seed' is not a Git checkout."
if [ -z "$checkout" ] && [ -n "$(git -C "$seed" status --porcelain)" ]; then
  fail "seed '$seed' has uncommitted changes; a new clone copies committed HEAD only."
fi
if [ -n "$checkout" ] && [ ! -d "$(dirname "$seed")/$checkout" ] && [ ! -d "$checkout" ]; then
  fail "checkout '$checkout' does not exist beside the seed."
fi

json_field() {
  python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[k]
print(d if d is not None else "")' "$1"
}

pane_state() {
  herdr pane get "$1" | python3 -c 'import json,sys
p=json.load(sys.stdin)["result"]["pane"]
print(p.get("agent") or "none", p.get("agent_status") or "unknown")'
}

# Many harnesses share one machine: cap each one's test workers, and say so
# in the objective, because not every runner reads the environment.
fleet_note="Fleet note: this machine runs several harnesses at once. Run test suites one at a time, and give any runner at most $max_workers workers (the VITEST_MAX_WORKERS variable is set to $max_workers; always pass --workers 2 to Playwright, whose default takes half the cores). Never push, never open a pull request, and never land on, merge into or change the seed checkout: commit in your clone and stop, because the fleet manager lands the work. The e2e suite uses fixed ports shared by every checkout on this machine, so never run pnpm test:e2e directly: run the full e2e suite only through the seed checkout script .atomic/fleet/e2e-check.sh with this clone path as its argument, if that script exists, because it waits its turn behind a machine-wide lock and uses its own scratch database; that script runs one worker, which is the required e2e verification and not a deviation from the two-worker rule, which applies only to the component suite. Writers and reviewers verify against this clone's own test and e2e databases only, never the shared local development database, and check who owns a port before using it. Do not commit implementation notes, handoff documents or review ledgers to the repository; put what the fleet manager needs in your final report."
if [ -z "$resolve_only" ]; then
  objective="${objective:+$objective }$fleet_note"
fi
# The objective travels inside one double-quoted input, so a double quote in
# it would end the value early and the rest would be read as more inputs.
objective="${objective//\"/\'}"

# A first launch needs a fresh clearance from clear.sh: proof that the
# issue's blockers were read from the tracker and are all landed. A follow-up
# run in an existing clone (--checkout) and a preview (--resolve-only) do not.
if [ -z "$resolve_only" ] && { [ -z "$checkout" ] || [ "$checkout" = auto ]; }; then
  clearance="$seed/.atomic/fleet/clearance/$issue.md"
  [ -f "$clearance" ] || fail "no clearance for $issue. Read its blockers in the tracker and run clear.sh first."
  [ -n "$(find "$clearance" -mmin -30)" ] || fail "the clearance for $issue is older than 30 minutes. Read its blockers again and re-run clear.sh."
fi

created="$(herdr tab create --workspace "$workspace" --cwd "$seed" --label "$issue" \
  --env "VITEST_MAX_WORKERS=$max_workers" --no-focus)"
tab="$(printf '%s' "$created" | json_field result.tab.tab_id)"
pane="$(printf '%s' "$created" | json_field result.root_pane.pane_id)"
echo "tab=$tab"
echo "pane=$pane"

herdr pane run "$pane" atomic >/dev/null

waited=0
until case "$(pane_state "$pane")" in "atomic idle"|"atomic done") true ;; *) false ;; esac; do
  [ "$waited" -lt "$timeout" ] || fail "Atomic was not ready in pane $pane after ${timeout}s; the tab is left open."
  sleep 2; waited=$((waited + 2))
done

command_line="/workflow $workflow"
[ "$tracker" = none ] || command_line="$command_line tracker=$tracker tracker_issue=$issue"
command_line="$command_line model_policy_path=$policy_path"
[ -z "$checkout" ] || command_line="$command_line branch_checkout_dir=$checkout"
[ -z "$resolve_only" ] || command_line="$command_line resolve_only=true"
if [ -n "$objective" ]; then
  # JSON-quote so spaces, quotes and newlines survive as one key=value token.
  quoted="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$objective")"
  command_line="$command_line objective=$quoted"
fi

herdr pane send-text "$pane" "$command_line" >/dev/null
sleep 1
herdr pane send-keys "$pane" Enter >/dev/null

run_id=""
waited=0
while [ -z "$run_id" ]; do
  [ "$waited" -lt "$timeout" ] || fail "no dispatch seen in pane $pane after ${timeout}s; read the pane before retrying."
  sleep 3; waited=$((waited + 3))
  run_id="$(herdr pane read "$pane" 2>/dev/null |
    grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1 || true)"
done

echo "run_id=$run_id"
echo "policy=$policy_path"
echo "state=$(pane_state "$pane")"
