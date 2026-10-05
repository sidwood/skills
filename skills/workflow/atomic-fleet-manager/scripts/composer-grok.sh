#!/usr/bin/env bash
# The composer-grok harness: one Cursor CLI writer and one Cursor CLI reviewer
# working an issue in a branch clone, in rounds, until the reviewer approves
# or the round limit is reached. Runs inside the issue's Herdr tab and reports
# its state to Herdr so the fleet's status and watch scripts see it.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: composer-grok.sh --issue ID --clone DIR --brief FILE [options]

  --issue ID         Tracker issue identifier (TUS-36)
  --clone DIR        Branch clone to work in
  --brief FILE       Work definition: the issue text with acceptance criteria
  --base REF         Commit the clone started from (default: its HEAD now)
  --writer MODEL     Cursor model that writes (default: composer-2.5)
  --reviewer MODEL   Cursor model that reviews (default: grok-4.7-xhigh)
  --rounds N         Review rounds before giving up (default: 3)
USAGE
}

issue="" clone="" brief="" base="" writer="composer-2.5" reviewer="grok-4.7-xhigh" rounds=3
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --clone) clone="$2"; shift 2 ;;
    --brief) brief="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --writer) writer="$2"; shift 2 ;;
    --reviewer) reviewer="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$issue" ] || [ -z "$clone" ] || [ -z "$brief" ]; then
  usage >&2
  exit 2
fi
[ -d "$clone/.git" ] || { echo "Error: '$clone' is not a Git checkout." >&2; exit 1; }
[ -f "$brief" ] || { echo "Error: brief '$brief' does not exist." >&2; exit 1; }
command -v cursor-agent >/dev/null || { echo "Error: cursor-agent is not on PATH." >&2; exit 1; }

clone="$(cd "$clone" && pwd)"
state="$clone/.atomic/composer-grok"
mkdir -p "$state"
cp "$brief" "$state/brief.md"
[ -n "$base" ] || base="$(git -C "$clone" rev-parse HEAD)"
started=$(date +%s)

report() { # state message
  local elapsed=$(( ($(date +%s) - started) / 60 ))
  echo "composer-grok · $2 · ${elapsed}m"
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    herdr pane report-agent --source composer-grok --agent composer-grok \
      --state "$1" --message "$2" "$HERDR_PANE_ID" >/dev/null 2>&1 || true
  fi
}

finish() { # herdr-state outcome detail
  {
    echo "# $issue: composer-grok result"
    echo
    echo "- Outcome: $2"
    echo "- Detail: $3"
    echo "- Writer: $writer; reviewer: $reviewer; rounds used: ${round:-0} of $rounds"
    echo "- Base: $base"
    echo "- Commits:"
    git -C "$clone" log --oneline "$base..HEAD" | sed 's/^/  - /'
    echo "- Tree clean: $([ -z "$(git -C "$clone" status --porcelain)" ] && echo yes || echo no)"
    echo "- Last review: $state/round-${round:-0}-review.md"
  } > "$state/result.md"
  cat "$state/result.md"
  report "$1" "$2"
  exit 0
}

cd "$clone" || exit 1
chat="$(cursor-agent create-chat 2>/dev/null | tail -1)"
[ -n "$chat" ] || { round=0; finish blocked "failed" "could not create a Cursor chat"; }

writer_rules="Rules: work only inside this checkout ($clone). Read AGENTS.md first and follow it, including how to run commands and the commit-message rules (imperative subject of at most 50 characters, no attribution trailers). The work definition is the file .atomic/composer-grok/brief.md; its acceptance criteria are the contract, so do exactly what they require and nothing beyond. Run the checks AGENTS.md names for the code you touched (type check, lint, the relevant test suites) and fix what fails; this machine runs several harnesses at once, so run suites one at a time and pass --workers=${VITEST_MAX_WORKERS:-4} to Playwright. Before stating any command, path, port or name in code or documentation, confirm it exists in this repository; when you correct a mistake, search the whole repository for the same mistake and correct every instance the issue covers. Commit your work with a body that says why the change was made and names the issue; never push, never open a pull request, never change the tracker. Finish with a short summary: what you changed, which checks you ran with their results, and anything you could not do."

round=0
while [ "$round" -lt "$rounds" ]; do
  round=$((round + 1))

  report working "round $round/$rounds · writer"
  if [ "$round" -eq 1 ]; then
    prompt="You are implementing tracker issue $issue. $writer_rules"
  else
    prompt="A reviewer examined your work on $issue and requested changes. Its findings are in .atomic/composer-grok/round-$((round - 1))-review.md. Address every finding, or say precisely why one is wrong. $writer_rules"
  fi
  cursor-agent -p --force --trust --model "$writer" --resume "$chat" "$prompt" \
    > "$state/round-$round-writer.log" 2>&1
  writer_exit=$?
  tail -15 "$state/round-$round-writer.log"
  [ "$writer_exit" -eq 0 ] || finish blocked "failed" "writer exited $writer_exit in round $round; see $state/round-$round-writer.log"

  if [ -z "$(git -C "$clone" log --oneline "$base..HEAD")" ]; then
    finish blocked "failed" "writer made no commit in round $round"
  fi

  report working "round $round/$rounds · reviewer"
  git -C "$clone" diff "$base..HEAD" > "$state/round-$round.diff"
  git -C "$clone" status --porcelain > "$state/round-$round-status.txt"
  review_prompt="You are reviewing an implementation of tracker issue $issue. You are read-only: do not edit files. Read .atomic/composer-grok/brief.md (the work definition; its acceptance criteria are the contract), AGENTS.md (the repository rules), the full change in .atomic/composer-grok/round-$round.diff, the uncommitted-files list in .atomic/composer-grok/round-$round-status.txt, the writer's own summary at the end of .atomic/composer-grok/round-$round-writer.log, and whatever source files you need for context. Check, in order: each acceptance criterion is met by the diff; nothing outside the issue's scope was changed; tests exist for the behavior and would fail without the change; the repository rules are followed; every command, path, port and name the change states exists in the repository; a mistake fixed in one place is not left elsewhere in the files the issue covers; each commit message has a body and names the issue; nothing is left uncommitted that should be committed. Be specific and skeptical; do not approve on the writer's word. Reply with numbered findings, each naming file and line and the observable problem, most serious first, or say there are none. The last line of your reply must be exactly 'VERDICT: APPROVED' or 'VERDICT: CHANGES_REQUESTED'."
  cursor-agent -p --mode ask --trust --model "$reviewer" "$review_prompt" \
    > "$state/round-$round-review.md" 2>&1
  review_exit=$?
  tail -25 "$state/round-$round-review.md"
  [ "$review_exit" -eq 0 ] || finish blocked "failed" "reviewer exited $review_exit in round $round; see $state/round-$round-review.md"

  verdict="$(grep -E '^[[:space:]*`]*VERDICT: (APPROVED|CHANGES_REQUESTED)' "$state/round-$round-review.md" | tail -1 | grep -Eo 'APPROVED|CHANGES_REQUESTED' || true)"
  case "$verdict" in
    APPROVED)
      if [ -n "$(git -C "$clone" status --porcelain)" ]; then
        finish blocked "approved but tree is dirty" "uncommitted files remain; see $state/round-$round-status.txt"
      fi
      finish idle "approved in round $round" "reviewer approved; ready to land"
      ;;
    CHANGES_REQUESTED) ;;
    *) finish blocked "failed" "reviewer gave no verdict line in round $round; see $state/round-$round-review.md" ;;
  esac
done

finish blocked "not approved after $rounds rounds" "reviewer still requests changes; see $state/round-$round-review.md"
