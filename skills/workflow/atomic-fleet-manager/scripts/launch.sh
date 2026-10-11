#!/usr/bin/env bash
# Start one Atomic goal-select harness in its own Herdr tab and confirm it was
# dispatched. Prints one "key=value" line per fact for the caller to read.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: launch.sh --issue ID --tier TIER --writer MODEL [options]
       launch.sh --issue ID --policy PATH [options]

  --issue ID           Tracker issue identifier, also the tab label (TUS-150)
  --tier TIER          Review tier from the issue's label: simple, standard
                       or complex (the shared policy defines each)
  --writer MODEL       Writer model with effort (xai/grok-4.7:xhigh)
  --orchestrator MODEL Orchestrator model (default: the shared policy's)
  --policy PATH        A policy file instead of the shared one; its
                       top-level keys override the tier for this run
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

issue="" policy="" tier="" writer="" orchestrator="" tracker="linear" checkout="" objective="" seed="$PWD"
workspace="${HERDR_WORKSPACE_ID:-}" workflow="goal-select" resolve_only=""
timeout=60 max_workers=4
policy_dir="${ATOMIC_POLICY_DIR:-$HOME/.config/atomic/goal-select-models}"

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --policy) policy="$2"; shift 2 ;;
    --tier) tier="$2"; shift 2 ;;
    --writer) writer="$2"; shift 2 ;;
    --orchestrator) orchestrator="$2"; shift 2 ;;
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
# A follow-up in an existing clone is small work on reviewed code: it gets
# the simple tier unless told otherwise, and the gate is its proof.
if [ -z "$tier" ] && [ -z "$policy" ] && [ -n "$checkout" ] && [ "$checkout" != auto ]; then tier="simple"; fi
[ -n "$policy" ] || [ -n "$tier" ] || fail "--tier is required (or --policy for a policy file)."
case "$tier" in ""|simple|standard|complex) ;; *) fail "--tier must be simple, standard or complex, got '$tier'." ;; esac
[ -n "$policy" ] || [ -n "$writer" ] || fail "--writer is required with --tier."
[ -n "$workspace" ] || fail "no Herdr workspace; pass --workspace."
command -v atomic >/dev/null || fail "atomic is not on PATH."

case "$policy" in
  "") policy_path="$HOME/.config/atomic/goal-select.jsonc" ;;
  */*|*.json|*.jsonc) policy_path="$policy" ;;
  *) policy_path="$policy_dir/$policy.json" ;;
esac
[ -f "$policy_path" ] || fail "policy file '$policy_path' does not exist."

# Prime directive: a model line never reviews its own work.
same_line="$(python3 - "$policy_path" "$tier" "$writer" <<'PY'
import json, re, sys
text = re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[1]).read())
try:
    policy = json.loads(text)
except ValueError:
    sys.exit(0)  # JSONC this check cannot parse; the workflow validates it
line = lambda m: (m or "").split("/")[-1].split(":")[0]
tier = policy.get("review_tiers", {}).get(sys.argv[2], {}) if sys.argv[2] else {}
writer = line(sys.argv[3] or policy.get("writer_model") or policy.get("orchestrator_model"))
reviewers = {line(v) for k, v in list(tier.items()) + list(policy.items()) if k.endswith("reviewer_model") and v}
if writer and writer in reviewers:
    print(writer)
PY
)"
[ -z "$same_line" ] || fail "policy '$policy_path' has '$same_line' as both writer and reviewer; a model line must not review itself."

# Every provider a stage will use must be ready now: a stage on an unready
# provider fails instead of running. That includes the writer's fallbacks
# (the policy's writer_fallbacks for its model line): a fallback whose
# provider has no login is started on the orchestrator's model, which the
# workflow can only catch afterwards.
providers="$(python3 - "$policy_path" "$tier" "$writer" "$orchestrator" "$HOME/.config/atomic/goal-select.jsonc" <<'PY'
import json, re, sys
def load(path):
    try:
        return json.loads(re.sub(r"(?m)^\s*//.*$", "", open(path).read()))
    except (OSError, ValueError):
        return {}
policy = load(sys.argv[1])
tier = policy.get("review_tiers", {}).get(sys.argv[2], {}) if sys.argv[2] else {}
models = [sys.argv[3], sys.argv[4], policy.get("defaults", {}).get("orchestrator_model"), policy.get("defaults", {}).get("reverify_model")]
models += [v for k, v in list(policy.items()) + list(tier.items()) if k.endswith("_model") and isinstance(v, str)]
# A policy file without the key inherits the shared file's chains.
chains = policy["writer_fallbacks"] if "writer_fallbacks" in policy else load(sys.argv[5]).get("writer_fallbacks", {})
line = re.sub(r":[a-z]+$", "", sys.argv[3] or "")
if isinstance(chains, dict) and isinstance(chains.get(line), list):
    models += [m for m in chains[line] if isinstance(m, str)]
print(" ".join(sorted({m.split("/")[0] for m in models if m and "/" in m})))
PY
)"
for provider in $providers; do
  # The check exits non-zero when not ready; keep its word, not its exit.
  state="$(atomic auth check --provider "$provider" 2>&1 | head -1 || true)"
  [ -n "$state" ] || state="unknown"
  [ "$state" = ready ] || fail "provider '$provider' is $state; log Atomic in to it before launching (atomic auth check --provider $provider)."
done

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
fleet_note="Fleet note: this machine runs several harnesses at once. Run test suites one at a time, and give any runner at most $max_workers workers (the VITEST_MAX_WORKERS variable is set to $max_workers; always pass --workers 2 to Playwright, whose default takes half the cores). Never push, never open a pull request, and never land on, merge into or change the seed checkout: commit in your clone and stop, because the fleet manager lands the work. The e2e suite uses fixed ports shared by every checkout on this machine, so never run pnpm test:e2e directly: run the full e2e suite only through the seed checkout script .atomic/fleet/e2e-check.sh with this clone path as its argument, if that script exists, because it waits its turn behind a machine-wide lock and uses its own scratch database; that script runs one worker, which is the required e2e verification and not a deviation from the two-worker rule, which applies only to the component suite. Writers and reviewers verify against this clone's own test and e2e databases only, never the shared local development database, and check who owns a port before using it. Commit messages say what changed and why and never name the tracker issue, in the subject or the body. Do not commit implementation notes, handoff documents or review ledgers to the repository; put what the fleet manager needs in your final report. When this run ends, with or without approval, report and stop: the session that started it never starts another run for this issue, because the fleet manager decides what follows a run that stopped at its round limit."
# The gate note goes out only where the project has a gate script.
gate_script="$seed/.atomic/fleet/gate.sh"
if [ -x "$gate_script" ]; then
  fleet_note="$fleet_note The writer's final step each round: run the landing gate on this clone, $gate_script <this clone path> (it runs the project's install, typecheck, lint, unit, integration, e2e and component checks, about 15 minutes of running, longer with a queue), with its output saved in a log file in the clone under .atomic/, and quote its first and last lines in the report. Only the writer runs the gate, on the commit it reports. The writer runs it again only after changing code or when a run was cut off before it finished (a timeout, an aborted command); say so in the report when that happens. A reviewer never runs the gate or a whole suite: only two gates run at a time across this machine, and a second run of the same commit only makes every harness wait. A reviewer reads the writer's gate log (its first line names the commit, its last line must be GATE_OK), checks that commit is the one under review, and runs single test files or its own probes to verify a claim. Only two gates run at a time across this machine: a GATE_WAITING line means both slots are taken and yours starts when one ends, so keep polling and never run two gates at once or stop a waiting one. Start the gate, and any suite that runs longer than a minute, as a background task with its output in a log file, then poll the log: a message arriving from another agent aborts whatever command you have in the foreground, and the gate must not be killed halfway. Report the work ready only when that line is GATE_OK; otherwise fix what it names first. The fleet manager runs the same gate again on the stacked train, so a writer that skips it is sent back. Everything in this fleet note is a working rule for the agents, not an acceptance criterion of the issue: a reviewer judges the change and the gate result for the reviewed commit, and reports a slip in procedure in its notes without withholding approval for it."
fi
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
[ -z "$tier" ] || command_line="$command_line review_tier=$tier"
[ -z "$writer" ] || command_line="$command_line writer_model=$writer"
[ -z "$orchestrator" ] || command_line="$command_line orchestrator_model=$orchestrator"
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
  # The run id is the newest UUID in the pane that is not part of a path
  # shown there (a scratch checkout under a session directory carries one).
  run_id="$(herdr pane read "$pane" 2>/dev/null |
    grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
    grep -v -F -x -f <(printf '%s\n%s\n' "$seed" "$checkout" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; echo "no-uuid") |
    tail -1 || true)"
done

echo "run_id=$run_id"
# Record the run this pane was launched with: status.sh compares it with the
# run the pane shows, to catch a session that starts another run by itself.
launch_log="${XDG_STATE_HOME:-$HOME/.local/state}/atomic-fleet/launched.tsv"
mkdir -p "$(dirname "$launch_log")"
printf '%s\t%s\t%s\t%s\n' "$pane" "$issue" "$run_id" "$(date +%s)" >>"$launch_log"
echo "policy=$policy_path"
echo "tier=${tier:-from policy} writer=${writer:-from policy}"
echo "state=$(pane_state "$pane")"
