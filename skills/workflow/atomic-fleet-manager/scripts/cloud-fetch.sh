#!/usr/bin/env bash
# Bring a finished cloud-lane unit into a local clone that the landing train
# can take, and print what it holds.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cloud-fetch.sh --unit KEY [--seed DIR]

  --unit KEY  Unit key in the branch name (m2-u8 fetches ready/m2-u8)
  --seed DIR  Seed checkout (default: current directory)

Makes, or refreshes, the clone <seed>.cloud-KEY at the tip of origin's
ready/KEY and prints its base on the seed, its commits, and a check of their
messages. The clone then lands like any harness clone: stack it on the seed
tip from the printed base, run the gate, land, review, clean up.
USAGE
}

unit="" seed="$PWD"
while [ $# -gt 0 ]; do
  case "$1" in
    --unit) unit="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$unit" ] || { echo "Error: --unit is required." >&2; usage >&2; exit 2; }

url="$(git -C "$seed" remote get-url --push origin)"
clone="$seed.cloud-$unit"
[ -d "$clone" ] || git bc-add --offline "$seed" "cloud-$unit" "$clone" >/dev/null
GIT_TERMINAL_PROMPT=0 git -C "$clone" fetch -q "$url" "ready/$unit"
git -C "$clone" checkout -q -B "cloud-$unit" FETCH_HEAD
base="$(git -C "$clone" merge-base HEAD "$(git -C "$seed" rev-parse HEAD)")"

echo "clone=$clone"
echo "tip=$(git -C "$clone" rev-parse --short HEAD)"
echo "base=$(git -C "$clone" rev-parse --short "$base") (seed is at $(git -C "$seed" rev-parse --short HEAD))"
echo "commits=$(git -C "$clone" rev-list --count "$base"..HEAD)"
git -C "$clone" log --reverse --format='%h %an: %s' "$base"..HEAD
# Tracker ids, attribution trailers and tool names do not belong in a message.
# TRACKER_KEYS is the tracker's own key or keys (TUS, or TUS|OPS). A loose
# "letters, dash, digits" pattern trips on UTF-8 and SHA-256, so it is the
# fallback only when no key is given.
ticket="${TRACKER_KEYS:+\\b(${TRACKER_KEYS})-[0-9]+\\b}"
echo "bad_messages=$(git -C "$clone" log --format=%B "$base"..HEAD | grep -ciE "${ticket:-[A-Z]{2,5}-[0-9]+}|co-authored|generated with|cursor" || true)"
echo "long_subjects=$(git -C "$clone" log --format=%s "$base"..HEAD | awk 'length($0)>50' | wc -l | tr -d ' ')"
# Authorship is attribution too: a commit an agent authored shows on the
# host as two people. Expect one line, the repository owner's.
echo "authors=$(git -C "$clone" log --format='%an|%cn' "$base"..HEAD | sort -u | tr '\n' ';')"
echo "files=$(git -C "$clone" diff --name-only "$base"..HEAD | wc -l | tr -d ' ')"
