#!/usr/bin/env bash
# Start one composer-grok harness: make a branch clone from the seed, open a
# Herdr tab named for the issue, and run composer-grok.sh in it. Prints one
# "key=value" line per fact for the caller to read.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: launch-composer-grok.sh --issue ID --brief FILE [options]

  --issue ID         Tracker issue identifier, also the tab label (TUS-36)
  --brief FILE       Work definition written from the tracker issue
  --seed DIR         Seed checkout to clone from (default: current directory)
  --workspace ID     Herdr workspace (default: $HERDR_WORKSPACE_ID)
  --writer MODEL     Passed to composer-grok.sh (default: composer-2.5)
  --reviewer MODEL   Passed to composer-grok.sh (default: grok-4.7-xhigh)
  --rounds N         Passed to composer-grok.sh (default: 3)
USAGE
}

issue="" brief="" seed="$PWD" workspace="${HERDR_WORKSPACE_ID:-}"
writer="composer-2.5" reviewer="grok-4.7-xhigh" rounds=3
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --brief) brief="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --writer) writer="$2"; shift 2 ;;
    --reviewer) reviewer="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "Error: $1" >&2; exit 1; }

[ "${HERDR_ENV:-}" = 1 ] || fail "not running inside a Herdr pane."
[ -n "$issue" ] || fail "--issue is required."
[ -f "$brief" ] || fail "--brief must name an existing file."
[ -n "$workspace" ] || fail "no Herdr workspace; pass --workspace."
command -v cursor-agent >/dev/null || fail "cursor-agent is not on PATH."
cursor-agent status 2>/dev/null | grep -q "Logged in" || fail "cursor-agent is not logged in."

seed="$(cd "$seed" && pwd)"
clearance="$seed/.atomic/fleet/clearance/$issue.md"
[ -f "$clearance" ] || fail "no clearance for $issue. Read its blockers in the tracker and run clear.sh first."
[ -n "$(find "$clearance" -mmin -30)" ] || fail "the clearance for $issue is older than 30 minutes. Read its blockers again and re-run clear.sh."
[ -z "$(git -C "$seed" status --porcelain)" ] || fail "seed '$seed' has uncommitted changes."
base="$(git -C "$seed" rev-parse HEAD)"

slug="$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
branch="goal-$slug-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
clone="$seed.$branch"
git bc-add --offline "$seed" "$branch" >/dev/null 2>&1 || fail "git bc-add failed for branch $branch."
[ -d "$clone/.git" ] || fail "clone '$clone' was not created."

mkdir -p "$clone/.atomic/composer-grok"
cp "$brief" "$clone/.atomic/composer-grok/brief.md"

driver="$(cd "$(dirname "$0")" && pwd)/composer-grok.sh"
created="$(herdr tab create --workspace "$workspace" --cwd "$clone" --label "$issue" \
  --env "VITEST_MAX_WORKERS=${FLEET_MAX_WORKERS:-4}" --no-focus)"
read -r tab pane <<EOF
$(printf '%s' "$created" | python3 -c 'import json,sys
r=json.load(sys.stdin)["result"]
print(r["tab"]["tab_id"], r["root_pane"]["pane_id"])')
EOF

herdr pane run "$pane" "$driver" --issue "$issue" --clone "$clone" \
  --brief "$clone/.atomic/composer-grok/brief.md" --base "$base" \
  --writer "$writer" --reviewer "$reviewer" --rounds "$rounds" >/dev/null

echo "tab=$tab"
echo "pane=$pane"
echo "clone=$clone"
echo "base=$base"
echo "writer=$writer"
echo "reviewer=$reviewer"
