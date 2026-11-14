#!/usr/bin/env bash
# Start one Atomic harness on another machine from the fleet manager's own:
# copy the issue's clearance and the named files there, run this skill's
# launch.sh there through hc exec, name its GUI tab, and record the unit for
# remote-watch.sh. Prints launch.sh's key=value lines with the terminal's
# full address (machine/tN), plus machine= and clone=.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: remote-launch.sh --on MACHINE --remote-seed DIR --issue ID [options] [-- launch.sh options]

  --on MACHINE          hc machine to run on (hc machine ls)
  --remote-seed DIR     The project's seed checkout on that machine
  --issue ID            Tracker issue identifier, passed to launch.sh
  --file LOCAL=REMOTE   Copy a file there first (repeatable): the brief, the
                        objective, the issue text for --tracker none. A
                        relative REMOTE is under the remote seed. Refuses
                        .env files, keys and credentials.
  --name NAME           Unit name in the units file (default: the issue)
  --max-terminals N     Refuse when this project already has N harness
                        terminals on that machine (default 6)
  --max-load N          Refuse at or above this 1-minute load there
                        (default: two thirds of its cores)
  --units FILE          Units file remote-watch.sh reads (default:
                        .atomic/fleet/remote-units.txt in the seed)
  --seed DIR            The fleet manager's seed (default: current directory)
  --space ID            The fleet's GUI space (default: the caller's own)

Everything after -- goes to launch.sh as given: --tier, --policy, --writer,
--checkout, --tracker none, --objective, --agent-dir, --base-branch and the
rest. Paths in them are paths on that machine.

The machine must be cleared for this project: a line naming it in
.atomic/fleet/remote-machines.txt in the seed, with the user's words. A
project holding company data needs the user's explicit yes for each
machine. Nothing else crosses: no .env file, key or credential is copied.

Units file lines: NAME RUN_ID MACHINE/tN CLONE_ON_MACHINE (CLONE is - when
launch.sh made the clone and its folder could not be read).
USAGE
}

fail() { echo "Error: $1" >&2; exit 1; }

machine="" remote_seed="" issue="" name="" max_terminals=6 max_load="" units="" seed="$PWD" space=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --on) machine="$2"; shift 2 ;;
    --remote-seed) remote_seed="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --file) files+=("$2"); shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --max-terminals) max_terminals="$2"; shift 2 ;;
    --max-load) max_load="$2"; shift 2 ;;
    --units) units="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --space|--workspace) space="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done
launch_args=("$@")

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$here/fleet-hc.sh"
fleet_need_hc
[ -n "$machine" ] || fail "--on is required."
[ -n "$remote_seed" ] || fail "--remote-seed is required."
[ -n "$issue" ] || fail "--issue is required."
name="${name:-$issue}"
seed="$(cd "$seed" && pwd)"
units="${units:-$seed/.atomic/fleet/remote-units.txt}"
[ -n "$space" ] || space="$(fleet_space)"
[ -n "$space" ] || fail "no GUI space: run inside an hc terminal of the fleet or pass --space."
project="$(fleet_project "$space")"

# The user clears each machine for each project.
cleared="$seed/.atomic/fleet/remote-machines.txt"
grep -Eq "^[[:space:]]*$machine([[:space:]]|$)" "$cleared" 2>/dev/null ||
  fail "$machine is not cleared for $project: add a line '$machine <the user's words and date>' to $cleared once the user has said yes."

hc machine ls --json 2>/dev/null | python3 -c 'import json,sys
m=[x for x in json.load(sys.stdin)["machines"] if x["name"]==sys.argv[1]]
sys.exit(0 if m and m[0]["state"]=="connected" else 1)' "$machine" ||
  fail "hc machine $machine is not connected (hc machine ls)."

# Room on that machine: this project's harness terminals there, and its load.
open_now="$(fleet_snapshot "$space" | awk -F'\t' -v m="$machine/" 'index($1, m) == 1 && ($3 == "harness" || $4 == "atomic")' | wc -l | tr -d ' ')"
[ "$open_now" -lt "$max_terminals" ] ||
  fail "$project already has $open_now harness terminals on $machine (limit $max_terminals); close finished ones first."
load="$(fleet_remote_load "$machine")"
if [ -z "$max_load" ]; then
  cores="$(fleet_remote "$machine" 'getconf _NPROCESSORS_ONLN' 30)"
  max_load=$(( ${cores:-3} * 2 / 3 ))
fi
awk -v l="$load" -v m="$max_load" 'BEGIN { exit !(l < m) }' ||
  fail "the 1-minute load on $machine is $load (limit $max_load); launch when it falls."

# What crosses: the clearance and the named files, never secrets.
copy() { # local remote
  local base
  base="$(basename "$1")"
  case "$base" in
    .env|.env.*|*.pem|*.key|id_*|auth.json|*credential*|*secret*|*.p12|*.pfx)
      fail "refusing to copy '$1': .env files, keys and credentials never go to another machine." ;;
  esac
  [ -f "$1" ] || fail "no file '$1' to copy."
  case "$2" in /*) target="$2" ;; *) target="$remote_seed/$2" ;; esac
  hc file write --on "$machine" "$target" <"$1" >/dev/null || fail "could not copy '$1' to $machine:$target."
}
clearance="$seed/.atomic/fleet/clearance/$issue.md"
[ ! -f "$clearance" ] || copy "$clearance" ".atomic/fleet/clearance/$issue.md"
for pair in ${files[@]+"${files[@]}"}; do
  copy "${pair%%=*}" "${pair#*=}"
done

skill="$(fleet_push_skill "$machine")" || fail "could not copy the skill's scripts to $machine."
quoted="$(printf ' %q' "${launch_args[@]+"${launch_args[@]}"}")"
out="$(fleet_remote "$machine" "cd $(printf %q "$remote_seed") && FLEET_PROJECT=$(printf %q "$project") $(printf %q "$skill")/launch.sh --seed $(printf %q "$remote_seed") --space $(printf %q "$space") --issue $(printf %q "$issue")$quoted" 600 2>&1)" || {
  printf '%s\n' "$out" | tail -8 >&2
  fail "launch.sh failed on $machine."
}

local_address="$(printf '%s\n' "$out" | sed -n 's/^terminal=//p' | tail -1)"
[ -n "$local_address" ] || { printf '%s\n' "$out" | tail -8 >&2; fail "launch.sh on $machine printed no terminal."; }
address="$machine/$local_address"
run_id="$(printf '%s\n' "$out" | sed -n 's/^run_id=//p' | tail -1)"
# Every line as launch.sh printed it, with the terminal's full address.
printf '%s\n' "$out" | sed -E "s#^(terminal|tab|pane)=.*#\\1=$address#"
echo "machine=$machine"

fleet_name_tab "$address" "$issue"

# The clone: the --checkout given, or the branch Atomic planned beside the seed.
clone="-"
for ((i = 0; i < ${#launch_args[@]}; i++)); do
  if [ "${launch_args[i]}" = --checkout ] && [ $((i + 1)) -lt ${#launch_args[@]} ]; then clone="${launch_args[i + 1]}"; fi
done
case "$clone" in -|auto) clone="-" ;; /*) ;; *) clone="$(dirname "$remote_seed")/$clone" ;; esac
if [ "$clone" = "-" ]; then
  branch="$(fleet_read "$address" 400 | grep -Eo 'Planned branch: [A-Za-z0-9._/-]+' | tail -1 | sed 's/^Planned branch: //; s/[.,]$//' || true)"
  [ -z "$branch" ] || clone="$remote_seed.$branch"
fi
echo "clone=$clone"

if [ -n "$run_id" ]; then
  # status.sh on this machine compares the run a terminal shows with this.
  launch_log="${XDG_STATE_HOME:-$HOME/.local/state}/atomic-fleet/launched.tsv"
  mkdir -p "$(dirname "$launch_log")"
  printf '%s\t%s\t%s\t%s\n' "$address" "$issue" "$run_id" "$(date +%s)" >>"$launch_log"
  mkdir -p "$(dirname "$units")"
  printf '%s %s %s %s\n' "$name" "$run_id" "$address" "$clone" >>"$units"
  echo "units=$units"
fi
