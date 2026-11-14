#!/usr/bin/env bash
# Watch the fleet's harnesses on other machines from the fleet manager's own,
# through hc alone (no SSH sessions), and exit with one line on the first
# thing that needs the fleet manager. Run it in the background; its exit is
# the wake-up. Re-arm it after handling each event: a new copy for the same
# units file stops the old one.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: remote-watch.sh [--units FILE] [options]

  --units FILE        Units to watch, one per line:
                      NAME RUN_ID MACHINE/tN CLONE [R]
                      (remote-launch.sh writes them; default
                      .atomic/fleet/remote-units.txt in the current folder).
                      R marks a resumed run whose ledger stays needs_human:
                      it is reported when its orchestrator receipt changes.
  --quiet-min N       Report a run whose ledger is active but whose
                      Atomic sessions have written nothing for N minutes
                      (default 20)
  --auto-resume N     Resume a run Atomic paused or quit (load spikes do
                      that) up to N times each without waking the fleet
                      manager (default 0: report it instead). Attempts go
                      to the log.
  --log FILE          Auto-resume log (default: the units file + .log)
  --interval SECONDS  Check every this often (default 60)
  --timeout SECONDS   Exit with TIMEOUT after this long (default 43200)
  --space ID          The fleet's GUI space (default: the caller's own)

Reports, one line, then exit 0:
  ENDED    the run's ledger left active (complete, handover, needs_human,
           failed), or a resumed run wrote its receipt
  STALLED  the ledger says active but the terminal has been at rest with
           no run shown for three checks
  QUIET    the ledger says active but nothing was written for --quiet-min
  GONE     the terminal has ended
  PAUSED   a paused run that auto-resume did not bring back
  TIMEOUT
USAGE
}

units=".atomic/fleet/remote-units.txt" quiet_min=20 auto_resume=0 log="" interval=60 timeout=43200 space=""
while [ $# -gt 0 ]; do
  case "$1" in
    --units) units="$2"; shift 2 ;;
    --quiet-min) quiet_min="$2"; shift 2 ;;
    --auto-resume) auto_resume="$2"; shift 2 ;;
    --log) log="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --space|--workspace) space="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$here/fleet-hc.sh"
fleet_need_hc
[ -f "$units" ] || { echo "Error: no units file '$units'." >&2; exit 2; }
units="$(cd "$(dirname "$units")" && pwd)/$(basename "$units")"
log="${log:-$units.log}"
[ -n "$space" ] || space="$(fleet_space)"
project="$(fleet_project "$space")"

# One watcher per units file: a new one replaces the old.
pidfile="$units.watch.pid"
old="$(cat "$pidfile" 2>/dev/null || true)"
if [ -n "$old" ] && [ "$old" != $$ ] && kill -0 "$old" 2>/dev/null; then kill "$old" 2>/dev/null || true; fi
echo $$ >"$pidfile"
trap '[ "$(cat "$pidfile" 2>/dev/null)" = $$ ] && rm -f "$pidfile"' EXIT

# Read on the machine: per run, the ledger status, minutes since the run's
# sessions (or, without a known clone, its run folder) were last written,
# and the orchestrator receipt's time.
probe='
import glob, json, os, sys, time
def newest(path):
    best = 0
    for d, _, files in os.walk(path):
        for f in files:
            try:
                best = max(best, os.path.getmtime(os.path.join(d, f)))
            except OSError:
                pass
    return best
for spec in sys.argv[1:]:
    run, clone = spec.split("=", 1)
    roots = [r for r in glob.glob(os.path.expanduser("~/.atomic*")) if os.path.isdir(os.path.join(r, "workflows", "runs", run))]
    if not roots:
        print(run, "none", -1, 0)
        continue
    rundir = os.path.join(roots[0], "workflows", "runs", run)
    ledgers = glob.glob(os.path.join(rundir, "artifact-*", "goal-ledger.json"))
    try:
        status = json.load(open(ledgers[0])).get("status") or "none" if ledgers else "none"
    except (OSError, ValueError):
        status = "unreadable"
    last = 0
    if clone != "-":
        last = newest(os.path.join(roots[0], "agent", "sessions", "--" + clone.strip("/").replace("/", "-") + "--"))
    last = last or newest(rundir)
    receipts = glob.glob(os.path.join(rundir, "artifact-*", "orchestrator-receipt.md"))
    receipt = int(os.path.getmtime(receipts[0])) if receipts else 0
    print(run, status, int((time.time() - last) / 60) if last else -1, receipt)
'

declare -A stalls tries receipt_base
skill_on=""
report() { echo "$1"; exit 0; }
start=$(date +%s)
while :; do
  machines="$(awk 'NF >= 4 && $1 !~ /^#/ { split($3, a, "/"); print a[1] }' "$units" | sort -u)"
  [ -n "$machines" ] || report "NO UNITS in $units"
  for machine in $machines; do
    specs=()
    while read -r name run address clone mark; do
      case "$address" in "$machine"/*) specs+=("$run=$clone") ;; esac
    done < <(awk 'NF >= 4 && $1 !~ /^#/' "$units")
    facts="$(printf '%s' "$probe" | hc exec --on "$machine" --timeout 60 -i -- python3 - "${specs[@]}" 2>/dev/null)" || continue
    while read -r name run address clone mark; do
      case "$address" in "$machine"/*) ;; *) continue ;; esac
      read -r _ status quiet receipt <<<"$(printf '%s\n' "$facts" | awk -v r="$run" '$1 == r')"
      [ -n "${status:-}" ] || continue
      state="$(fleet_state "$address")"
      [ "$state" != "none gone" ] || report "GONE at $(date +%H:%M): $name's terminal $address has ended (run $run, ledger $status)"
      if [ "${mark:-}" = R ]; then
        [ -n "${receipt_base[$run]:-}" ] || receipt_base[$run]="$receipt"
        [ "$receipt" = "${receipt_base[$run]}" ] || report "ENDED at $(date +%H:%M): $name (resumed) wrote its receipt"
      else
        case "$status" in
          active|none|unreadable) ;;
          *) report "ENDED at $(date +%H:%M): $name is $status" ;;
        esac
      fi
      [ "$status" = active ] || [ "${mark:-}" = R ] || continue
      screen="$(fleet_read "$address" || true)"
      held="$(printf '%s\n' "$screen" | grep -Eo 'BACKGROUND .*[0-9]+ (paused|quit)' | grep -Eo '(paused|quit)' | tail -1 || true)"
      if [ -n "$held" ]; then
        n="${tries[$run]:-0}"
        [ "$n" -lt "$auto_resume" ] || report "PAUSED at $(date +%H:%M): $name's run $run is $held on $machine ($n automatic resumes tried; see $log)"
        tries[$run]=$((n + 1))
        if [ "$skill_on" != "$machine" ]; then skill="$(fleet_push_skill "$machine")" && skill_on="$machine"; fi
        out="$(fleet_remote "$machine" "FLEET_PROJECT=$(printf %q "$project") $(printf %q "$skill")/resume.sh --issue $(printf %q "$name") --run $run --terminal ${address#*/} --space $(printf %q "$space")" 600 2>&1 | tail -1 | cut -c1-160)"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $name $run try $((n + 1)): $out" >>"$log"
        case "$out" in *RESUMED*|*COMPLETED*) tries[$run]=0 ;; esac
        continue
      fi
      # At rest with no run shown, three checks running: a stage that never
      # restarted. A chat idle while its workflow runs still lists the run
      # in its BACKGROUND box as "●  <run id>"; only that line counts.
      case "${state#* }" in
        done|idle)
          if printf '%s\n' "$screen" | grep -qE "●[[:space:]]+$run"; then stalls[$run]=0; else stalls[$run]=$(( ${stalls[$run]:-0} + 1 )); fi ;;
        *) stalls[$run]=0 ;;
      esac
      [ "${stalls[$run]}" -lt 3 ] || report "STALLED at $(date +%H:%M): $name's ledger says active but $address reads ${state#* } with no run shown"
      if [ "$quiet" -ge "$quiet_min" ] 2>/dev/null; then
        report "QUIET at $(date +%H:%M): $name ($run) active but nothing written for $quiet min"
      fi
    done < <(awk 'NF >= 4 && $1 !~ /^#/' "$units")
  done
  [ $(( $(date +%s) - start )) -lt "$timeout" ] || report "TIMEOUT at $(date +%H:%M)"
  sleep "$interval"
done
