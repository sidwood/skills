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
  --fresh             After a restart or a killed terminal, reopen the
                      session that owns the chain run: atomic --session with
                      the full session id, in a new terminal. Close the old
                      terminal first (hc kill, hc rm).
  --cwd DIR           Working directory for --fresh (default: the run's own)
  --agent-dir DIR     Atomic agent directory for --fresh, when the run was
                      launched under a second account (launch.sh --agent-dir)
  --terminal T        The run's terminal (default: the one named for the
                      issue, found through status.sh)
  --space ID          The fleet's GUI space (default: the caller's own;
                      --workspace is the old name). Needed through hc exec.
  --max-load N        Refuse above this 1-minute load average (default 12)
  --timeout SECONDS   Wait this long for the run to go live (default 300)
  --status            Print the run's journal state and exit; resume nothing

Prints `RESUMED: <issue> <run id> <latest stage>` once the run is live.
`--status` also prints `session=`, the full id of the owning session.
Exits 1 with the reason when the run cannot be resumed or ends blocked.
USAGE
}

issue="" run="" message="" fresh="" cwd="" terminal="" max_load=12 timeout=300 status_only="" agent_dir=""
workspace=""
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
command -v python3 >/dev/null || fail "python3 is not installed; it reads the run's state from Atomic's workflow journal."
if [ -n "$agent_dir" ]; then
  agent_dir="${agent_dir/#\~/$HOME}"
fi

# Run state lives in the workflow journal (a sqlite catalog beside the agent
# directory), not in Postgres. A stage id is not a run: the chain run is the
# catalog row, and the session that owns it is recorded on that row.
read_state() {
  local out error_file line key val
  error_file="$(mktemp)"
  if ! out="$(python3 - "$issue" "${run:-}" "${agent_dir:-}" 2>"$error_file" <<'PY'
import json, os, re, sqlite3, sys, time
from datetime import datetime, timezone

issue, given, agent_dir = sys.argv[1:4]
FULL_ID = re.compile(
    r"\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)

def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)

def full_id(value):
    return bool(FULL_ID.match(value or ""))

def journal_dir():
    override = os.environ.get("ATOMIC_WORKFLOW_JOURNAL_PATH", "").strip()
    if override:
        return os.path.expanduser(override)
    if agent_dir:
        parent = os.path.dirname(os.path.realpath(os.path.expanduser(agent_dir)))
        return os.path.join(parent, "workflows", "journal")
    return os.path.expanduser("~/.atomic/workflows/journal")

def session_dir():
    if agent_dir:
        return os.path.join(os.path.realpath(os.path.expanduser(agent_dir)), "sessions")
    return os.path.expanduser("~/.atomic/agent/sessions")

def ro(path):
    return sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)

def file_ms(name):
    stamp = name.split("_", 1)[0]
    if not stamp.endswith("Z"):
        return None
    try:
        date, clock = stamp[:-1].split("T")
        hh, mm, ss, ms = clock.split("-")
        iso = "%sT%s:%s:%s.%sZ" % (date, hh, mm, ss, ms)
        parsed = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
        return int(parsed.timestamp() * 1000)
    except ValueError:
        return None

def find_owner(directory, run_id, created_ms):
    # The launching session is the jsonl just before the run whose first
    # line has no workflow key and whose body records workflow.run.start
    # for this chain run. Stage sessions carry a workflow key and are not it.
    if not created_ms or not os.path.isdir(directory):
        return ""
    start = created_ms - 10 * 60 * 1000
    end = created_ms + 60 * 1000
    found = []
    try:
        names = os.listdir(directory)
    except OSError:
        return ""
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        stamp = file_ms(name)
        if stamp is None or stamp < start or stamp > end:
            continue
        path = os.path.join(directory, name)
        try:
            handle = open(path)
        except OSError:
            continue
        with handle:
            try:
                meta = json.loads(handle.readline())
            except json.JSONDecodeError:
                continue
            if "workflow" in meta:
                continue
            sid = meta.get("id") or ""
            if not full_id(sid):
                continue
            hit = False
            for count, line in enumerate(handle):
                if run_id in line and "workflow.run.start" in line:
                    hit = True
                    break
                if count > 400:
                    break
            if hit:
                found.append((stamp, sid))
    if not found:
        return ""
    found.sort()
    return found[-1][1]

root = journal_dir()
catalog_path = os.path.join(root, "catalog.sqlite")
if not os.path.isfile(catalog_path):
    die("Atomic's workflow journal is not at %s." % root)
cat = ro(catalog_path)
shards = {}

def shard_con(shard_id):
    if shard_id not in shards:
        path = cat.execute("SELECT path FROM catalog_shards WHERE id = ?", (shard_id,)).fetchone()
        if not path:
            die("journal shard %s is missing from the catalog." % shard_id)
        shards[shard_id] = ro(os.path.join(root, path[0]))
    return shards[shard_id]

def header_of(con, run_id):
    row = con.execute(
        "SELECT header_json, status, created_at FROM wf_runs WHERE run_id = ?",
        (run_id,),
    ).fetchone()
    if not row:
        return {}, "", 0
    try:
        header = json.loads(row[0]) if row[0] else {}
    except json.JSONDecodeError:
        header = {}
    return header, row[1] or "", row[2] or 0

def event(con, run_id, kind):
    row = con.execute(
        "SELECT payload FROM wf_events WHERE run_id = ? AND type = ? ORDER BY seq DESC LIMIT 1",
        (run_id, kind),
    ).fetchone()
    if not row or not row[0]:
        return {}
    try:
        return json.loads(row[0])
    except json.JSONDecodeError:
        return {}

def stage_name(con, run_id):
    row = con.execute(
        "SELECT payload FROM wf_events WHERE run_id = ? AND type = 'CheckpointRecorded' "
        "AND key LIKE ? ORDER BY seq DESC LIMIT 1",
        (run_id, '%,"stage",%'),
    ).fetchone()
    if not row or not row[0]:
        return ""
    try:
        return json.loads(row[0]).get("name") or ""
    except json.JSONDecodeError:
        return ""

def catalog_row(run_id):
    return cat.execute(
        "SELECT run_id, shard, status, updated_at, cwd, root_run_id FROM catalog_runs WHERE run_id = ?",
        (run_id,),
    ).fetchone()

if given:
    if not full_id(given):
        die("run %s is not a full chain run id. A stage id, or an 8-character prefix, is not a run." % given)
    row = catalog_row(given)
    if not row:
        die("run %s is not in the workflow journal. Resume the chain run id from the BACKGROUND panel; a stage id is not a run." % given)
    chain = row[5] or row[0]
    if chain != row[0]:
        die("run %s belongs to chain run %s. Resume the chain run." % (given, chain))
    chosen = row
else:
    cutoff = int((time.time() - 7 * 86400) * 1000)
    rows = cat.execute(
        "SELECT run_id, shard, status, updated_at, cwd, root_run_id FROM catalog_runs "
        "WHERE updated_at > ? AND (root_run_id IS NULL OR root_run_id = '' OR root_run_id = run_id) "
        "ORDER BY updated_at DESC",
        (cutoff,),
    ).fetchall()
    chosen = None
    for row in rows:
        header, _status, _created = header_of(shard_con(row[1]), row[0])
        if (header.get("inputs") or {}).get("tracker_issue") == issue:
            chosen = row
            break
    if not chosen:
        die("no run for %s in the last 7 days; pass --run." % issue)

run_id, shard, cat_status, cat_updated, cat_cwd, _chain = chosen
con = shard_con(shard)
header, wf_status, created_at = header_of(con, run_id)
latest = event(con, run_id, "StatusChanged")
started = event(con, run_id, "RunStarted")
status = latest.get("status") or cat_status or wf_status or started.get("status") or ""
updated = latest.get("updatedAt") or cat_updated or started.get("updatedAt") or 0
cwd = latest.get("invocationCwd") or started.get("invocationCwd") or header.get("cwd") or cat_cwd or ""
resumable = latest.get("resumable", started.get("resumable", True))
error = latest.get("error") or started.get("error") or ""
owner = latest.get("modelOwner") or started.get("modelOwner") or ""
if not full_id(owner):
    owner = find_owner(session_dir(), run_id, created_at or started.get("createdAt") or 0)
idle = max(0, int(time.time() - (updated / 1000))) if updated else 0
if status == "running" and idle > 120:
    status = "crashed"
stage = stage_name(con, run_id)
error = " ".join(str(error).split())[:200]

def emit(key, value):
    print("%s=%s" % (key, value))

emit("run", run_id)
emit("status", status)
emit("resumable", "true" if resumable else "false")
emit("idle_seconds", idle)
emit("cwd", cwd)
emit("error", error)
emit("latest_stage", stage)
emit("session", owner if full_id(owner) else "")
PY
  )"; then
    local message
    message="$(cat "$error_file")"
    rm -f "$error_file"
    fail "${message:-could not read the workflow journal.}"
  fi
  rm -f "$error_file"
  status="" resumable="" idle="" run_cwd="" error="" stage="" session=""
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      run) run="$val" ;;
      status) status="$val" ;;
      resumable) resumable="$val" ;;
      idle_seconds) idle="$val" ;;
      cwd) run_cwd="$val" ;;
      error) error="$val" ;;
      latest_stage) stage="$val" ;;
      session) session="$val" ;;
    esac
  done <<<"$out"
  [ -n "$status" ] || fail "run ${run:-unknown} has no recorded state."
  [ -n "$idle" ] || idle=0
}

read_state

if [ -n "$status_only" ]; then
  printf 'issue=%s\nrun=%s\nstatus=%s\nresumable=%s\nidle_seconds=%s\nlatest_stage=%s\ncwd=%s\nerror=%s\nsession=%s\n' \
    "$issue" "$run" "$status" "$resumable" "$idle" "$stage" "$run_cwd" "$error" "$session"
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
  # Reopening the owning session while it is still live would start a
  # second copy of it.
  [ "$idle" -ge 120 ] || fail "run $run was written ${idle}s ago. Resume it in its own terminal, or wait 120s before --fresh reopens the owning session."
  [ -n "$session" ] || fail "run $run has no owning session id in the journal. An 8-character prefix is ambiguous, and the full id was not recorded."
  dir="${cwd:-$run_cwd}"
  [ -d "$dir" ] || fail "the run's working directory '$dir' is gone; pass --cwd."
  run_env=(env)
  if [ -n "$agent_dir" ]; then
    [ -f "$agent_dir/auth.json" ] || fail "--agent-dir '$agent_dir' has no auth.json."
    run_env=(env -u ANTHROPIC_API_KEY "ATOMIC_CODING_AGENT_DIR=$agent_dir")
  fi
  # fleet_open is already --no-parent. The full session id reopens the
  # owner; a new empty `atomic` cannot resume this run.
  pane="$(fleet_open "$issue" harness "$dir" --space "$workspace" -- "${run_env[@]}" atomic --session "$session")" ||
    fail "could not open a terminal for $issue."
  waited=0
  until case "$(pane_state "$pane")" in "atomic idle"|"atomic done") true ;; *) false ;; esac; do
    [ "$waited" -lt 60 ] || fail "Atomic was not ready in terminal $pane after 60s; the terminal is left open."
    sleep 2; waited=$((waited + 2))
  done
  fleet_name_tab "$pane" "$issue"
else
  pane="$terminal"
  [ -n "$pane" ] || pane="$("$here/status.sh" "$workspace" | awk -F'\t' -v l="$issue" '$1 == l { print $2 }' | tail -1)"
  [ -n "$pane" ] || fail "no terminal named $issue; use --fresh to reopen the owning session."
  case "$(pane_state "$pane")" in
    "atomic working") fail "the Atomic session in $pane is busy; read it (hc read $pane) before resuming." ;;
    atomic*) ;;
    *) fail "terminal $pane has no Atomic session; use --fresh to reopen the owning session." ;;
  esac
fi
# Plain language in the owning session. The slash command is read as a
# stage name, and from a new empty session it fails as another caller.
text="Fleet manager: resume workflow run $run where it stopped. Do not start a new run."
if [ -n "$message" ]; then
  text="Fleet manager: resume workflow run $run where it stopped. Do not start a new run. News for the orchestrator: $message"
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
status_before="$status"
blocked_grace=90
submit "$text"

waited=0
while :; do
  sleep 5; waited=$((waited + 5))
  if [ -z "$requit" ] && [ "$(refusals)" -gt "$refused_before" ]; then
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
  read_state
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

echo "RESUMED: $issue $run ${stage:-unknown}"
echo "terminal=$pane"
echo "pane=$pane"
