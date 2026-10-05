#!/usr/bin/env bash
# Record that an issue's blockers were read and are all landed, and that
# starting it keeps the fleet inside its work-in-progress limit. launch.sh
# refuses a first launch without a fresh clearance, so an issue cannot be
# started on memory or on a hunch.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: clear.sh --issue ID --execution-order TEXT --in-progress N --finishing N
                --area-clash none|ID [--blocker ID=STATE]... [options]

  --issue ID               Tracker issue identifier (TUS-58)
  --blocker ID=STATE       One per blocker, with the state read from the
                           tracker just now. Repeat for every blocker: the
                           issue's blocked-by relations AND every issue its
                           text says to start after. Omit only when there
                           are none.
  --execution-order TEXT   The sentence from the issue that says when it may
                           start, copied from the tracker, or "none" if the
                           issue has no such section
  --area TEXT              The part of the code it mainly touches
  --in-progress N          Issues started and not yet Done, counted in the
                           tracker just now: running, waiting to land, in
                           review, or back for a fix. Do not count this issue.
  --finishing N            Of those, how many are waiting to land or in review
  --area-clash none|ID     An in-progress issue working in the same code area,
                           or "none" after checking each one's area
  --web                    This issue is mainly web work
  --web-in-progress N      In-progress issues that are mainly web work
                           (required with --web)
  --wip-limit N            Most issues in progress at once (default 4)
  --web-limit N            Most web issues in progress at once (default 2)
  --finishing-limit N      Refuse while this many are finishing (default 2)
  --user-exception TEXT    The user's own words allowing this issue to start
                           past a limit. Blockers are never excepted.
  --seed DIR               Seed checkout (default: current directory)

A blocker counts as landed when its state is Done or In Review. Any other
state refuses the clearance and names the blocker.

Work in progress: the clearance is refused when starting this issue would
put more than --wip-limit issues in progress, more than --web-limit web
issues in progress, when --finishing-limit or more are already waiting to
land or in review (finish those first), or when another in-progress issue
works in the same code area.
USAGE
}

issue="" order="" area="" seed="$PWD"
in_progress="" finishing="" clash="" web="" web_in_progress="" exception=""
wip_limit=4 web_limit=2 finishing_limit=2
blockers=()
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --blocker) blockers+=("$2"); shift 2 ;;
    --execution-order) order="$2"; shift 2 ;;
    --area) area="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --in-progress) in_progress="$2"; shift 2 ;;
    --finishing) finishing="$2"; shift 2 ;;
    --area-clash) clash="$2"; shift 2 ;;
    --web) web=1; shift ;;
    --web-in-progress) web_in_progress="$2"; shift 2 ;;
    --wip-limit) wip_limit="$2"; shift 2 ;;
    --web-limit) web_limit="$2"; shift 2 ;;
    --finishing-limit) finishing_limit="$2"; shift 2 ;;
    --user-exception) exception="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "Error: $1" >&2; exit 1; }

[ -n "$issue" ] || fail "--issue is required."
[ -n "$order" ] || fail "--execution-order is required: copy the sentence from the issue, or pass \"none\" after reading the whole description."

open=()
for b in "${blockers[@]+"${blockers[@]}"}"; do
  case "$b" in
    *=*) ;;
    *) fail "--blocker must be ID=STATE, got '$b'." ;;
  esac
  state="${b#*=}"
  case "$state" in
    Done|"In Review") ;;
    *) open+=("$b") ;;
  esac
done

# Every issue the execution-order sentence names must have been given as a
# blocker, so the prose and the relations are checked against each other.
prefix="${issue%%-*}"
for named in $(printf '%s' "$order" | grep -oE "$prefix-[0-9]+" | sort -u); do
  [ "$named" = "$issue" ] && continue
  found=""
  for b in "${blockers[@]+"${blockers[@]}"}"; do
    [ "${b%%=*}" = "$named" ] && found=1
  done
  [ -n "$found" ] || fail "the execution-order text names $named but no --blocker gives its state."
done

if [ "${#open[@]}" -gt 0 ]; then
  echo "NOT CLEAR: $issue waits for: ${open[*]}" >&2
  exit 1
fi

number() { case "$2" in ''|*[!0-9]*) fail "$1 must be a count read from the tracker now, got '$2'." ;; esac; }
number --in-progress "$in_progress"
number --finishing "$finishing"
[ -n "$clash" ] || fail "--area-clash is required: \"none\" after checking each in-progress issue's area, or the issue it clashes with."
[ -z "$web" ] || number --web-in-progress "$web_in_progress"

over=()
[ "$in_progress" -lt "$wip_limit" ] || over+=("$in_progress in progress, limit $wip_limit")
[ "$finishing" -lt "$finishing_limit" ] || over+=("$finishing waiting to land or in review: finish those first")
[ "$clash" = none ] || over+=("$clash is in progress in the same code area")
if [ -n "$web" ] && [ "$web_in_progress" -ge "$web_limit" ]; then
  over+=("$web_in_progress web issues in progress, limit $web_limit")
fi
if [ "${#over[@]}" -gt 0 ] && [ -z "$exception" ]; then
  printf 'NOT CLEAR: %s is over the work-in-progress limit: %s\n' "$issue" "$(IFS=';'; echo "${over[*]}")" >&2
  exit 1
fi

dir="$seed/.atomic/fleet/clearance"
mkdir -p "$dir"
{
  echo "# $issue clearance"
  echo
  echo "- Checked: $(date '+%Y-%m-%d %H:%M')"
  echo "- Blockers: ${blockers[*]:-none}"
  echo "- Execution order: $order"
  echo "- Area: ${area:-not stated}"
  echo "- In progress: $in_progress (limit $wip_limit), finishing: $finishing, web: ${web_in_progress:-not web}, area clash: $clash"
  [ "${#over[@]}" -eq 0 ] || echo "- Over limit: ${over[*]}; user exception: $exception"
} > "$dir/$issue.md"
echo "CLEAR: $issue ($dir/$issue.md)"
