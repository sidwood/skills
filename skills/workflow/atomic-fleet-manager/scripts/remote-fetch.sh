#!/usr/bin/env bash
# Carry a finished unit's branch from another machine to a clone on the fleet
# manager's machine, as a git bundle through hc, ready for the landing train.
# The remote clone must be clean. Makes the local clone when it is missing;
# refuses one with uncommitted changes. Prints one summary line: the local
# clone's head, its commits over the default branch, and their authors.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: remote-fetch.sh --on MACHINE --remote-clone DIR --remote-seed DIR [options]

  --on MACHINE         hc machine the unit ran on
  --remote-clone DIR   The unit's clone there
  --remote-seed DIR    The project's seed there (its default branch is the
                       base the bundle starts from)
  --clone DIR          Local clone to receive it (default: beside the seed,
                       named like the remote clone)
  --seed DIR           Local seed (default: current directory)
  --branch NAME        Default branch on both seeds (default: main)
  --local-branch NAME  Branch for a new local clone (default: unit/<the
                       remote clone's suffix>)

The local clone is reset to the fetched head, so it must hold no work of
its own: a clone that has commits the bundle lacks is refused.
USAGE
}

fail() { echo "Error: $1" >&2; exit 1; }

machine="" remote_clone="" remote_seed="" clone="" seed="$PWD" branch=main local_branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --on) machine="$2"; shift 2 ;;
    --remote-clone) remote_clone="$2"; shift 2 ;;
    --remote-seed) remote_seed="$2"; shift 2 ;;
    --clone) clone="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --local-branch) local_branch="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "$machine" ] || [ -z "$remote_clone" ] || [ -z "$remote_seed" ]; then
  usage >&2
  exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$here/fleet-hc.sh"
fleet_need_hc

seed="$(cd "$seed" && pwd)"
suffix="$(basename "$remote_clone")"
suffix="${suffix#*.}"
clone="${clone:-$(dirname "$seed")/$(basename "$seed").$suffix}"
local_branch="${local_branch:-unit/$suffix}"
main="$(git -C "$seed" rev-parse "$branch")"

# On the machine: the clone must be clean; the bundle holds its commits over
# the remote seed's default branch.
q() { printf %q "$1"; }
bundle_path=".local/state/atomic-fleet/bundles/$suffix-$$.bundle"
base="$(fleet_remote "$machine" "cd $(q "$remote_clone") || exit 1
[ -z \"\$(git status --porcelain)\" ] || { echo 'DIRTY'; exit 0; }
git fetch -q $(q "$remote_seed") $(q "$branch") || exit 1
base=\$(git merge-base HEAD FETCH_HEAD) || exit 1
[ \"\$base\" != \"\$(git rev-parse HEAD)\" ] || { echo 'EMPTY'; exit 0; }
mkdir -p \"\$HOME/.local/state/atomic-fleet/bundles\"
git bundle create \"\$HOME/$bundle_path\" \"\$base..HEAD\" >/dev/null 2>&1 || exit 1
echo \"\$base\"" 300)" || fail "could not make the bundle on $machine."
case "$base" in
  DIRTY) fail "the clone $remote_clone on $machine has uncommitted changes." ;;
  EMPTY) fail "the clone $remote_clone on $machine has no commits over $branch." ;;
esac
base="$(printf '%s\n' "$base" | tail -1)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
hc exec --on "$machine" --timeout 300 -- bash -c "cat \"\$HOME/$bundle_path\" && rm -f \"\$HOME/$bundle_path\"" >"$tmp/unit.bundle" ||
  fail "could not copy the bundle from $machine."
git bundle verify -q "$tmp/unit.bundle" >/dev/null 2>&1 || git -C "$seed" bundle verify -q "$tmp/unit.bundle" >/dev/null 2>&1 ||
  fail "the bundle from $machine did not verify (base ${base:0:8} may be missing here)."

if [ ! -d "$clone/.git" ]; then
  if command -v git-bc-add >/dev/null || git bc-add -h >/dev/null 2>&1; then
    git bc-add --offline "$seed" "$local_branch" "$clone" >/dev/null 2>&1 || fail "git bc-add could not make $clone."
  else
    git clone -q --local "$seed" "$clone" && git -C "$clone" checkout -q -b "$local_branch"
  fi
  # A new clone does not inherit the seed's hooks path.
  hooks="$(git -C "$seed" config core.hooksPath || true)"
  [ -z "$hooks" ] || git -C "$clone" config core.hooksPath "$hooks"
fi
[ -z "$(git -C "$clone" status --porcelain)" ] || fail "local clone $clone has uncommitted changes."
git -C "$clone" fetch -q "$seed" "$branch"
git -C "$clone" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$clone" fetch -q "$seed" "$base" 2>/dev/null ||
  fail "the base ${base:0:8} is not in the local seed; fetch the remote's $branch here first."
git -C "$clone" fetch -q "$tmp/unit.bundle" HEAD
fetched="$(git -C "$clone" rev-parse FETCH_HEAD)"
# Never drop local work: the clone's own commits must all be in the bundle.
[ -z "$(git -C "$clone" rev-list "$fetched..HEAD")" ] || fail "local clone $clone has commits the bundle lacks; nothing changed."
git -C "$clone" reset -q --hard "$fetched"

echo "fetched=$suffix clone=$clone head=$(git -C "$clone" log --oneline -1 | cut -c1-60) over_$branch=$(git -C "$clone" rev-list --count "$main..HEAD") base=${base:0:8} authors=$(git -C "$clone" log "$main..HEAD" --format='%an|%cn' | sort -u | tr '\n' ' ')"
