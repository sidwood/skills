#!/usr/bin/env bash
# Block until the cloud lane's branches for one unit change on origin, then
# say what changed. Run it in the background; its exit is the wake-up.
# Re-arm it after each event, as with watch.sh.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: cloud-watch.sh --unit KEY [--seed DIR] [--interval SECONDS] [--timeout SECONDS]

  --unit KEY          Unit key in the branch names (m2-u8 watches
                      unit/m2-u8 and ready/m2-u8)
  --seed DIR          Seed checkout (default: current directory)
  --interval SECONDS  Poll interval (default: 120)
  --timeout SECONDS   Give up and print NO CHANGE after this long
                      (default: 3300)

Prints one line and exits 0:
  STARTED     the work branch unit/KEY appeared
  READY       the ready branch ready/KEY appeared or moved
  MAIN_MOVED  origin's default branch holds a commit the seed lacks, which
              means someone other than the fleet manager pushed it
  NO CHANGE   the timeout passed

It lists over the seed's push URL, so a seed that pushes over HTTPS with the
GitHub CLI login is not stopped by a locked SSH agent.
USAGE
}

unit="" seed="$PWD" interval=120 timeout=3300
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) unit="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$unit" ] || { echo "Error: --unit is required." >&2; usage >&2; exit 2; }

url="$(git -C "$seed" remote get-url --push origin)" || exit 1
branch="$(git -C "$seed" branch --show-current)"
state_dir="$seed/.atomic/fleet/cloud"
mkdir -p "$state_dir"
state="$state_dir/$unit.state"
touch "$state"

start=$(date +%s)
work="" ready=""
while :; do
  refs="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$url" "refs/heads/unit/$unit" "refs/heads/ready/$unit" "refs/heads/$branch" 2>/dev/null)"
  if [ -n "$refs" ]; then
    work="$(printf '%s\n' "$refs" | awk -v r="refs/heads/unit/$unit" '$2==r{print $1}')"
    ready="$(printf '%s\n' "$refs" | awk -v r="refs/heads/ready/$unit" '$2==r{print $1}')"
    main="$(printf '%s\n' "$refs" | awk -v r="refs/heads/$branch" '$2==r{print $1}')"
    last_work="$(awk '$1=="work"{print $2}' "$state")"
    last_ready="$(awk '$1=="ready"{print $2}' "$state")"
    if [ -n "$main" ] && ! git -C "$seed" merge-base --is-ancestor "$main" HEAD 2>/dev/null; then
      echo "MAIN_MOVED at $(date '+%H:%M'): origin/$branch is $main, which the seed does not hold"
      exit 0
    fi
    if [ -n "$ready" ] && [ "$ready" != "$last_ready" ]; then
      printf 'work %s\nready %s\n' "$work" "$ready" > "$state"
      echo "READY at $(date '+%H:%M'): ready/$unit is $ready (unit/$unit is ${work:-absent})"
      exit 0
    fi
    if [ -n "$work" ] && [ -z "$last_work" ]; then
      printf 'work %s\nready %s\n' "$work" "$last_ready" > "$state"
      echo "STARTED at $(date '+%H:%M'): unit/$unit is $work"
      exit 0
    fi
  fi
  if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
    echo "NO CHANGE at $(date '+%H:%M') (unit/$unit: ${work:-none}, ready/$unit: ${ready:-none})"
    exit 0
  fi
  sleep "$interval"
done
