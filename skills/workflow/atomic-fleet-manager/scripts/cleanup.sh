#!/usr/bin/env bash
# Remove a landed harness: verify every commit in its clone is on the seed's
# remote default branch, then drop its test database, close its tab and remove
# the clone. Refuses, changing nothing, if any commit is not landed.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup.sh --clone DIR [--tab ID] [--seed DIR] [--remote-branch REF] [--db-drop CMD]

  --clone DIR          Branch clone to remove
  --tab ID             Herdr tab to close (optional)
  --seed DIR           Seed checkout (default: current directory)
  --remote-branch REF  Where landed work lives (default: origin/main)
  --db-drop CMD        Command run inside the clone to drop its test
                       database (default: "pnpm db:test:drop"; "" to skip)

A commit counts as landed when git cherry marks it "-", or when a commit
with the same subject on the remote branch carries the same changed lines
(a rebase can drop a hunk that landed through another issue; that still
counts only if no changed line is missing).
USAGE
}

clone="" tab="" seed="$PWD" remote="origin/main" db_drop="pnpm db:test:drop"
while [ $# -gt 0 ]; do
  case "$1" in
    --clone) clone="$2"; shift 2 ;;
    --tab) tab="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --remote-branch) remote="$2"; shift 2 ;;
    --db-drop) db_drop="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "Error: $1" >&2; exit 1; }
changed_lines() { git -C "$seed" show --format= "$1" | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | sort; }

[ -n "$clone" ] || fail "--clone is required."
[ -d "$clone/.git" ] || fail "'$clone' is not a Git checkout."
clone="$(cd "$clone" && pwd)"
[ -z "$(git -C "$clone" status --porcelain)" ] || fail "'$clone' has uncommitted changes."

git -C "$seed" fetch -q origin
git -C "$seed" fetch -q "$clone" HEAD
tip="$(git -C "$seed" rev-parse FETCH_HEAD)"

missing=0
for commit in $(git -C "$seed" cherry "$remote" "$tip" | awk '$1=="+"{print $2}'); do
  subject="$(git -C "$seed" log -1 --format=%s "$commit")"
  twin="$(git -C "$seed" log "$remote" --format=%H --fixed-strings --grep="$subject" -1)"
  if [ -z "$twin" ]; then
    echo "NOT LANDED: $(git -C "$seed" log -1 --format='%h %s' "$commit")" >&2
    missing=1
    continue
  fi
  # Every changed line of the clone's commit must appear in the landed one.
  lost="$(comm -23 <(changed_lines "$commit") <(changed_lines "$twin") | wc -l | tr -d ' ')"
  # A hunk another issue already landed is not lost: check the tree instead.
  if [ "$lost" -gt 0 ]; then
    files="$(git -C "$seed" show --format= --name-only "$commit")"
    # shellcheck disable=SC2086
    behind="$(git -C "$seed" diff "$tip" "$remote" -- $files | grep -cE '^-[^-]' || true)"
    if [ "$behind" -gt 0 ]; then
      echo "CHECK BY HAND: $(git -C "$seed" log -1 --format='%h %s' "$commit") differs from its landed twin $(git -C "$seed" rev-parse --short "$twin"), and the remote lacks $behind line(s) the clone has in those files." >&2
      missing=1
    fi
  fi
done
[ "$missing" -eq 0 ] || fail "the clone holds work that is not on $remote. Nothing was removed."

if [ -n "$db_drop" ]; then
  (cd "$clone" && $db_drop >/dev/null 2>&1) || echo "Warning: '$db_drop' failed in the clone." >&2
fi
if [ -n "$tab" ]; then
  herdr tab close "$tab" >/dev/null 2>&1 || echo "Warning: could not close tab $tab." >&2
fi
git bc-rm "$clone" -y 2>&1 | tail -1
echo "CLEANED: $clone"
