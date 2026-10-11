#!/usr/bin/env bash
# Stack one clone's commits onto the seed tip in the staging clone and run the
# landing checks. Prints GATE_OK on its own line only when everything passed.
# Usage: train.sh TRAIN_NUMBER CLONE_DIR BASE_COMMIT
set -uo pipefail

number="$1"
clone="$2"
base="$3"

seed=/Users/sidwood/code/casefilecrafter
staging=/Users/sidwood/code/casefilecrafter.train
logs=/private/tmp/claude-501/-Users-sidwood-code-casefilecrafter/74806b89-3582-46e1-88d5-4226d5fb7a1a/scratchpad
branch="train-$number"

cd "$staging" || exit 1
git rebase --abort 2>/dev/null
# shellcheck disable=SC2015  # Either step failing leaves staging unusable.
git fetch -q "$seed" main && git checkout -q -f -B "$branch" FETCH_HEAD || { echo "STACK_FAILED: could not reset staging"; exit 0; }
git fetch -q "$clone" "$(git -C "$clone" branch --show-current)" || { echo "STACK_FAILED: could not fetch clone"; exit 0; }
if ! git rebase -q --onto "$branch" "$base" FETCH_HEAD 2>/dev/null; then
  echo "STACK_CONFLICT"
  git status --short | grep -E "^(UU|AA|DU|UD)" | cut -c1-100 | head -8
  git rebase --abort 2>/dev/null
  exit 0
fi
git checkout -q -B "$branch" HEAD
# EXTRA_CLONES: more finished clones to stack in the same train, as
# space-separated CLONE_DIR=BASE pairs, in landing order.
for pair in ${EXTRA_CLONES:-}; do
  extra="${pair%%=*}"; extra_base="${pair#*=}"
  git fetch -q "$extra" "$(git -C "$extra" branch --show-current)" || { echo "STACK_FAILED: could not fetch $extra"; exit 0; }
  if ! git rebase -q --onto "$branch" "$extra_base" FETCH_HEAD 2>/dev/null; then
    echo "STACK_CONFLICT in $(basename "$extra")"
    git status --short | grep -E "^(UU|AA|DU|UD)" | cut -c1-100 | head -8
    git rebase --abort 2>/dev/null
    exit 0
  fi
  git checkout -q -B "$branch" HEAD
done
echo "STACK_OK $(git rev-list --count "$(git -C "$seed" rev-parse HEAD)"..HEAD) commits, migrations=$(git diff --stat "$(git -C "$seed" rev-parse HEAD)" HEAD | grep -c migrations)"
git log --oneline -3 | cut -c1-70

# Every check is the project's gate script, the same one each harness runs
# as its final step.
GATE_PRIORITY=1 GATE_LOG_DIR="$logs/train$number-gate" "$seed/.atomic/fleet/gate.sh" "$staging"
