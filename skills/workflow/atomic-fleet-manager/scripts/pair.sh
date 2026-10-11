#!/usr/bin/env bash
# A Cursor writer and a Cursor reviewer side by side in one Herdr tab, driven
# by the fleet manager one prompt at a time. Every prompt is typed into the
# agent's pane and is short enough to be read there in full; it names the
# brief and the standing rules, which are files in the clone under
# .atomic/pair/ beside a copy of each prompt and the agents' reports.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pair.sh open   --issue ID --brief FILE [options]
       pair.sh write  --issue ID [--note TEXT] [--max-rounds N]
       pair.sh review --issue ID [--note TEXT]
       pair.sh say    --issue ID --to writer|reviewer --note TEXT
       pair.sh status --issue ID

  open     Make a branch clone, open a tab named for the issue with the
           writer above the reviewer, and send the writer round 1.
  write    Send the writer the next round: the reviewer's findings.
  review   Send the reviewer the current round's work.
  say      Answer an agent inside the current round, without starting a
           new one: when it stopped to ask, or stopped before its report.
  status   One line: round, pane states, verdict, and what comes next.

  --issue ID         Tracker issue identifier, also the tab label (TUS-36)
  --brief FILE       Work definition written from the tracker issue (open)
  --note TEXT        The fleet manager's own words, appended to the prompt
  --to ROLE          With say: writer or reviewer
  --clone DIR        The pair's clone, when its tab cannot be found by label.
                     With open: a pair's clone whose panes are gone (new
                     agents, same round files), or with --brief another
                     harness's unfinished clone to start a pair on
  --seed DIR         Seed checkout to clone from (default: current directory)
  --workspace ID     Herdr workspace (default: $HERDR_WORKSPACE_ID)
  --writer MODEL     Cursor model that writes (default: composer-2.5)
  --reviewer MODEL   Cursor model that reviews (default: grok-4.7-xhigh)
  --max-rounds N     Writer rounds allowed (default: 3)
  --max-workers N    Test workers an agent may use (default: 4)
  --max-load N       open refuses at or above this 1-minute load (default: 12)

The writer and the reviewer must be different model lines.
USAGE
}

fail() { echo "Error: $1" >&2; exit 1; }

command="${1:-}"
[ $# -gt 0 ] && shift
issue="" brief="" note="" to="" clone="" seed="$PWD" workspace="${HERDR_WORKSPACE_ID:-}"
writer="" reviewer="" max_rounds="" max_workers="${FLEET_MAX_WORKERS:-4}" max_load=12
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --brief) brief="$2"; shift 2 ;;
    --note) note="$2"; shift 2 ;;
    --to) to="$2"; shift 2 ;;
    --clone) clone="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --writer) writer="$2"; shift 2 ;;
    --reviewer) reviewer="$2"; shift 2 ;;
    --max-rounds) max_rounds="$2"; shift 2 ;;
    --max-workers) max_workers="$2"; shift 2 ;;
    --max-load) max_load="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown argument '$1'." >&2; usage >&2; exit 2 ;;
  esac
done

case "$command" in
  open|write|review|say|status) ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "Error: unknown command '$command'." >&2; usage >&2; exit 2 ;;
esac
[ "${HERDR_ENV:-}" = 1 ] || fail "not running inside a Herdr pane."
[ -n "$issue" ] || fail "--issue is required."
[ -n "$workspace" ] || fail "no Herdr workspace; pass --workspace."

pane_state() { # pane -> working | idle | done | blocked | gone
  herdr pane get "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    pane = json.load(sys.stdin)["result"]["pane"]
except Exception:
    print("gone"); sys.exit()
print(pane.get("agent_status") or "unknown" if pane.get("agent") == "cursor" else "gone")'
}

# Issues that already have a pair open in this workspace, other than this one.
other_pairs() {
  local tabs
  tabs="$(herdr tab list --workspace "$workspace")"
  herdr pane list --workspace "$workspace" | TABS="$tabs" ISSUE="$issue" python3 -c '
import json, os, sys
labels = {t["tab_id"]: t["label"] for t in json.loads(os.environ["TABS"])["result"]["tabs"]}
found = set()
for pane in json.load(sys.stdin)["result"]["panes"]:
    label = labels.get(pane["tab_id"], "")
    if label != os.environ["ISSUE"] and os.path.isfile(os.path.join(pane.get("cwd") or "", ".atomic", "pair", "pair.env")):
        found.add(label)
print(" ".join(sorted(found)))'
}

# The clone of the tab labeled for the issue.
find_clone() {
  local tabs
  tabs="$(herdr tab list --workspace "$workspace")"
  herdr pane list --workspace "$workspace" | TABS="$tabs" ISSUE="$issue" python3 -c '
import json, os, sys
tabs = {t["tab_id"] for t in json.loads(os.environ["TABS"])["result"]["tabs"] if t["label"] == os.environ["ISSUE"]}
for pane in json.load(sys.stdin)["result"]["panes"]:
    cwd = pane.get("cwd") or ""
    if pane["tab_id"] in tabs and os.path.isfile(os.path.join(cwd, ".atomic", "pair", "pair.env")):
        print(cwd); break'
}

load_pair() {
  [ -n "$clone" ] || clone="$(find_clone)"
  [ -n "$clone" ] || fail "no pair tab labeled $issue in workspace $workspace; pass --clone."
  state="$clone/.atomic/pair"
  [ -f "$state/pair.env" ] || fail "'$clone' is not a pair clone (no .atomic/pair/pair.env)."
  local asked_rounds="$max_rounds"
  # shellcheck disable=SC1091
  . "$state/pair.env"
  [ -z "$asked_rounds" ] || max_rounds="$asked_rounds"
  gate="$seed/.atomic/fleet/gate.sh"
}

rounds_used() { find "$state" -name 'round-*-writer-prompt.md' | wc -l | tr -d ' '; }

verdict_of() { # round
  [ -f "$state/round-$1-review.md" ] || return 0
  grep -E '^[[:space:]*`]*VERDICT: (APPROVED|CHANGES_REQUESTED)' "$state/round-$1-review.md" |
    tail -1 | grep -Eo 'APPROVED|CHANGES_REQUESTED' || true
}

# Type the prompt file into the agent's pane and confirm the agent took it.
send() { # pane file
  local ack tries=0
  ack="$(herdr agent prompt "$1" "$(cat "$2")" 2>&1)" || fail "could not prompt pane $1: $ack"
  case "$ack" in *'"error"'*) fail "could not prompt pane $1: $ack" ;; esac
  while [ "$tries" -lt 15 ]; do
    [ "$(pane_state "$1")" = working ] && return 0
    sleep 2
    tries=$((tries + 1))
  done
  fail "pane $1 did not start working within 30 seconds; read it before sending anything else."
}

start_agent() { # pane name model
  local pane="$1" name="$2" model="$3" out screen trusted=0 tries=0
  out="$(herdr agent start "$name" --kind cursor --pane "$pane" --timeout 60000 -- --model "$model" -f 2>&1)" || true
  case "$out" in *'"error"'*) fail "could not start $name in pane $pane: $out" ;; esac
  # Cursor asks to trust a checkout it has not seen before it takes a prompt.
  while [ "$tries" -lt 30 ]; do
    screen="$(herdr pane read "$pane" --lines 40 2>/dev/null || true)"
    case "$screen" in
      *"Plan, search, build"*|*"Add a follow-up"*) return 0 ;;
      *"Trust this workspace"*)
        [ "$trusted" = 1 ] || herdr pane send-text "$pane" "a" >/dev/null
        trusted=1 ;;
    esac
    sleep 2
    tries=$((tries + 1))
  done
  fail "$name did not reach its prompt in pane $pane."
}

# The standing rules live in two files in the clone, so the prompts typed into
# the panes stay short: Cursor folds a prompt longer than about 500
# characters into a "[Pasted text]" marker, and a folded prompt cannot be
# read in the pane.
write_rules() {
  local gate_rule="" gate_read=""
  if [ -x "$gate" ]; then
    gate_rule="
- Last step of every round: run the landing gate on this checkout, \`$gate $clone\`, with its output in \`.atomic/pair/gate-N.log\`, where N is the round you are in. It runs install, typecheck, lint, unit, integration, the full end-to-end suite and the whole component suite: about 25 minutes, longer when it prints GATE_WAITING because another checkout holds the gate. Start it in the background and poll the log every few minutes, so no command timeout cuts it off, and stay in your turn until it has finished: a turn that ends while the gate is running leaves the round unfinished. Never start a second one, and never run the end-to-end suite directly. Fix what the gate names and run it again until its last line is GATE_OK."
    gate_read=" \`.atomic/pair/gate-N.log\` is its landing-gate run for round N."
  fi
  cat > "$state/writer-rules.md" <<EOF
# Rules for the writer of $issue

Your brief is \`.atomic/pair/brief.md\`. Its acceptance criteria are the contract: do exactly what they require and nothing beyond. Read it and \`AGENTS.md\` in full before you change anything.

- Work only inside this checkout (\`$clone\`), on its current branch. Never push, never open a pull request, never change the tracker, never touch another checkout.
- Follow \`AGENTS.md\` for how to run commands and for commit messages: an imperative subject of at most 50 characters, a body that says why, no tracker issue number anywhere in the message, and no attribution or Co-authored-by trailer. The commit hook rejects trailers; never pass \`--no-verify\`.
- Run the checks \`AGENTS.md\` names for the code you touch and fix what fails. This machine runs several agents at once: run suites one at a time and give any test runner at most $max_workers workers.
- Before stating a command, path, port or name in code or documentation, confirm it exists in this repository. When you correct a mistake, search for the same mistake elsewhere and correct every instance the issue covers.
- In a later round the reviewer's findings are in \`.atomic/pair/round-N-review.md\`. Address every finding, or say precisely why one is wrong.$gate_rule

## Finishing a round

Commit everything that belongs in the change. Then write \`.atomic/pair/round-N-writer.md\`, where N is the round (the file is not committed): what you changed and why, or what you did about each finding by its number; each check you ran with its result; the gate's last line if you ran it; and anything you could not do. Then stop.
EOF
  cat > "$state/reviewer-rules.md" <<EOF
# Rules for the reviewer of $issue

A different model wrote this work in the pane above. Do not edit, stage, commit or stash anything: the only file you write is your report.

## Read

- \`.atomic/pair/brief.md\`, the work definition. Its acceptance criteria are the contract.
- \`AGENTS.md\`, the repository rules.
- The change: every commit after the base your prompt names (\`git log\` and \`git diff\`).
- \`.atomic/pair/round-N-writer.md\`, the writer's report for round N.$gate_read Verify its claims; do not approve on the writer's word. You may run a single test file to check a claim, never a whole suite or the gate.
- \`git status\`: nothing that belongs in the change may be left uncommitted.

## Check, in order

1. Each acceptance criterion is met by the change.
2. Nothing outside the issue's scope was changed.
3. Tests exist for the behavior and would fail without the change.
4. The repository rules are followed.
5. Every command, path, port and name the change states exists in the repository.
6. A mistake fixed in one place is not left elsewhere in the files the issue covers.
7. Each commit message has a body that says why, names no tracker issue, and carries no attribution trailer.

## Report

Write \`.atomic/pair/round-N-review.md\`: numbered findings, most serious first, each with a severity from P0 to P3, the file and line, and the observable problem; or say there are none. Its last line must be exactly \`VERDICT: APPROVED\` or \`VERDICT: CHANGES_REQUESTED\`. Then stop.
EOF
}

# Type the prompt file into its pane; say so when it is too long to be shown.
deliver() { # role pane file round
  local chars
  [ -z "$note" ] || printf ' From the fleet manager: %s' "$note" >> "$3"
  chars="$(wc -m < "$3" | tr -d ' ')"
  send "$2" "$3"
  echo "sent=$1 round=$4 pane=$2 chars=$chars prompt=$3"
  [ "$chars" -le 500 ] || echo "note=this prompt is over 500 characters, so the pane shows it folded as [Pasted text]; the file has it in full."
}

write_round() {
  load_pair
  [ "$(pane_state "$writer_pane")" != working ] || fail "the writer is still working."
  [ "$(pane_state "$reviewer_pane")" != working ] || fail "the reviewer is still working."
  local round prev file
  round=$(( $(rounds_used) + 1 ))
  prev=$((round - 1))
  file="$state/round-$round-writer-prompt.md"
  if [ "$round" -gt 1 ]; then
    [ -f "$state/round-$prev-review.md" ] || fail "round $prev has no review yet; run 'pair.sh review' first."
    if [ "$(verdict_of "$prev")" = APPROVED ] && [ -z "$note" ]; then
      fail "round $prev was approved. Pass --note to send the writer something else."
    fi
    [ "$round" -le "$max_rounds" ] ||
      fail "all $max_rounds rounds are used. Hand the work over, or pass --max-rounds $round for one more."
  fi
  [ -f "$state/writer-rules.md" ] || write_rules

  if [ "$round" = 1 ]; then
    printf '%s' "You are the writer for $issue. Read .atomic/pair/writer-rules.md and .atomic/pair/brief.md in full, then do the work the brief defines. Finish by writing .atomic/pair/round-1-writer.md as the rules describe, then stop. The reviewer in the pane below examines your work next." > "$file"
  else
    printf '%s' "Round $round for $issue. The reviewer's findings are in .atomic/pair/round-$prev-review.md. Address every finding, or say precisely why one is wrong, under the same rules (.atomic/pair/writer-rules.md). Finish by writing .atomic/pair/round-$round-writer.md, then stop." > "$file"
  fi
  deliver writer "$writer_pane" "$file" "$round"
}

review_round() {
  load_pair
  [ "$(pane_state "$writer_pane")" != working ] || fail "the writer is still working."
  [ "$(pane_state "$reviewer_pane")" != working ] || fail "the reviewer is still working."
  local round prev file since=""
  round="$(rounds_used)"
  prev=$((round - 1))
  [ "$round" -gt 0 ] || fail "the writer has not had round 1 yet."
  [ -f "$state/round-$round-writer.md" ] ||
    fail "the writer left no report for round $round (.atomic/pair/round-$round-writer.md). Read pane $writer_pane."
  [ ! -f "$state/round-$round-review-prompt.md" ] || fail "round $round has already gone to the reviewer."
  [ ! -f "$state/round-$prev-head" ] ||
    since=" Changes since your last review: git diff $(cut -c1-12 "$state/round-$prev-head")..HEAD."
  [ -f "$state/reviewer-rules.md" ] || write_rules
  git -C "$clone" rev-parse HEAD > "$state/round-$round-head"
  file="$state/round-$round-review-prompt.md"
  printf '%s' "You are the reviewer for $issue, round $round. Read .atomic/pair/reviewer-rules.md and .atomic/pair/brief.md, then review the writer's work: git diff $(printf '%s' "$base" | cut -c1-12)..HEAD and its report .atomic/pair/round-$round-writer.md.$since Write .atomic/pair/round-$round-review.md ending with VERDICT: APPROVED or VERDICT: CHANGES_REQUESTED, then stop. Edit nothing else." > "$file"
  deliver reviewer "$reviewer_pane" "$file" "$round"
}

# A message inside the current round. It is kept beside the round's prompt
# and does not count as a round.
say_to() {
  load_pair
  local pane round count file text="$note"
  case "$to" in
    writer) pane="$writer_pane" ;;
    reviewer) pane="$reviewer_pane" ;;
    *) fail "--to must be writer or reviewer." ;;
  esac
  [ -n "$text" ] || fail "--note is required with say."
  [ "$(pane_state "$pane")" != working ] || fail "the $to is still working."
  round="$(rounds_used)"
  count="$(find "$state" -name "round-$round-$to-note-*.md" | wc -l | tr -d ' ')"
  file="$state/round-$round-$to-note-$((count + 1)).md"
  printf 'From the fleet manager: %s' "$text" > "$file"
  note=""
  deliver "$to" "$pane" "$file" "$round"
}

pair_status() {
  load_pair
  local round w r verdict dirty commits gate_line="" next
  round="$(rounds_used)"
  w="$(pane_state "$writer_pane")"
  r="$(pane_state "$reviewer_pane")"
  verdict="$(verdict_of "$round")"
  dirty="$(git -C "$clone" status --porcelain | wc -l | tr -d ' ')"
  commits="$(git -C "$clone" rev-list --count "$base..HEAD")"
  [ ! -f "$state/gate-$round.log" ] || gate_line="$(grep -E '^GATE_' "$state/gate-$round.log" | tail -1 | cut -d: -f1 || true)"
  if [ "$w" = gone ] || [ "$r" = gone ]; then next="reopen (an agent has left its pane): pair.sh open --issue $issue --clone $clone"
  elif [ "$w" = working ] || [ "$r" = working ]; then next="wait"
  elif [ "$round" = 0 ]; then next="write"
  elif [ ! -f "$state/round-$round-writer.md" ]; then next="read the writer's pane $writer_pane (no report for round $round), then answer it: pair.sh say --to writer --note ..."
  elif [ ! -f "$state/round-$round-review-prompt.md" ]; then next="review"
  elif [ -z "$verdict" ]; then next="read the reviewer's pane $reviewer_pane (no verdict for round $round), then answer it: pair.sh say --to reviewer --note ..."
  elif [ "$verdict" = APPROVED ] && [ "$dirty" != 0 ]; then next="write --note (approved, but $dirty files are uncommitted)"
  elif [ "$verdict" = APPROVED ] && [ -x "$gate" ] && [ "$gate_line" != GATE_OK ]; then next="write --note (approved, but the gate's last line is '${gate_line:-missing}')"
  elif [ "$verdict" = APPROVED ]; then next="land"
  elif [ "$round" -lt "$max_rounds" ]; then next="write"
  else next="hand over to QA with round-$round-review.md (one more round only for an open P0 or P1: write --max-rounds $((round + 1)))"
  fi
  echo "issue=$issue round=$round/$max_rounds writer=$w reviewer=$r commits=$commits dirty=$dirty gate=${gate_line:-none} verdict=${verdict:-none}"
  echo "clone=$clone base=$base tab=$tab writer_pane=$writer_pane reviewer_pane=$reviewer_pane"
  echo "next=$next"
}

open_pair() {
  command -v agent >/dev/null || fail "The Cursor command, agent, is not on PATH."
  agent status 2>/dev/null | grep -q "Logged in" || fail "The Cursor command, agent, is not logged in."
  seed="$(cd "$seed" && pwd)"
  local slug base="" reopened=0
  slug="$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
  [ -z "$(find_clone)" ] || fail "a pair tab labeled $issue is still open; close it before opening another."
  # One pair at a time: each handoff in a pair waits for the fleet manager.
  local open_pairs
  open_pairs="$(other_pairs)"
  [ -z "$open_pairs" ] || fail "a Cursor pair is already open for $open_pairs, and the limit is one. Give $issue to an Atomic writer from its tier label."

  if [ -n "$clone" ] && [ ! -f "$clone/.atomic/pair/pair.env" ]; then
    # Adopt a clone another harness left unfinished: its work stays, and the
    # pair starts at round 1 on top of it.
    clone="$(cd "$clone" && pwd)"
    [ -d "$clone/.git" ] || fail "'$clone' is not a git checkout."
    [ -f "$brief" ] || fail "'$clone' has no pair yet; pass --brief to start one on it."
    writer="${writer:-composer-2.5}" reviewer="${reviewer:-grok-4.7-xhigh}" max_rounds="${max_rounds:-3}"
    base="$(git -C "$clone" merge-base HEAD "$(git -C "$seed" rev-parse HEAD)")" || fail "'$clone' shares no history with the seed."
    state="$clone/.atomic/pair"
    mkdir -p "$state"
    cp "$brief" "$state/brief.md"
    git -C "$clone" check-ignore -q .atomic/pair/brief.md || echo ".atomic/" >> "$clone/.git/info/exclude"
  elif [ -n "$clone" ]; then
    clone="$(cd "$clone" && pwd)"
    reopened=1
    state="$clone/.atomic/pair"
    local asked_writer="$writer" asked_reviewer="$reviewer" asked_rounds="$max_rounds"
    # shellcheck disable=SC1091
    . "$state/pair.env"
    [ -z "$asked_writer" ] || writer="$asked_writer"
    [ -z "$asked_reviewer" ] || reviewer="$asked_reviewer"
    [ -z "$asked_rounds" ] || max_rounds="$asked_rounds"
  else
    writer="${writer:-composer-2.5}" reviewer="${reviewer:-grok-4.7-xhigh}" max_rounds="${max_rounds:-3}"
    [ -f "$brief" ] || fail "--brief must name an existing file."
    local clearance="$seed/.atomic/fleet/clearance/$issue.md"
    [ -f "$clearance" ] || fail "no clearance for $issue. Read its blockers in the tracker and run clear.sh first."
    [ -n "$(find "$clearance" -mmin -30)" ] || fail "the clearance for $issue is older than 30 minutes. Read its blockers again and re-run clear.sh."
    awk -v load="$(sysctl -n vm.loadavg | awk '{print $2}')" -v max="$max_load" 'BEGIN { exit !(load < max) }' ||
      fail "the 1-minute load is at or above $max_load; start nothing until it falls."
    [ -z "$(git -C "$seed" status --porcelain)" ] || fail "seed '$seed' has uncommitted changes."
    base="$(git -C "$seed" rev-parse HEAD)"
    local branch
    branch="goal-$slug-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    clone="$seed.$branch"
    git bc-add --offline "$seed" "$branch" >/dev/null 2>&1 || fail "git bc-add failed for branch $branch."
    [ -d "$clone/.git" ] || fail "clone '$clone' was not created."
    # A branch clone does not inherit the seed's hooks path, and the commit
    # hooks are what hold the writer to the message rules.
    local hooks
    hooks="$(git -C "$seed" config core.hooksPath || true)"
    [ -z "$hooks" ] || git -C "$clone" config core.hooksPath "$hooks"
    state="$clone/.atomic/pair"
    mkdir -p "$state"
    cp "$brief" "$state/brief.md"
    git -C "$clone" check-ignore -q .atomic/pair/brief.md || echo ".atomic/" >> "$clone/.git/info/exclude"
  fi
  # One model line never reviews its own work.
  [ "${writer%%-*}" != "${reviewer%%-*}" ] || fail "writer '$writer' and reviewer '$reviewer' are the same model line."

  local created split tab writer_pane reviewer_pane
  created="$(herdr tab create --workspace "$workspace" --cwd "$clone" --label "$issue" \
    --env "VITEST_MAX_WORKERS=$max_workers" --no-focus)"
  read -r tab writer_pane <<EOF
$(printf '%s' "$created" | python3 -c 'import json,sys
r=json.load(sys.stdin)["result"]
print(r["tab"]["tab_id"], r["root_pane"]["pane_id"])')
EOF
  start_agent "$writer_pane" "$slug-writer" "$writer"
  split="$(herdr pane split "$writer_pane" --direction down --cwd "$clone" \
    --env "VITEST_MAX_WORKERS=$max_workers" --no-focus)"
  reviewer_pane="$(printf '%s' "$split" | python3 -c 'import json,sys
print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')"
  start_agent "$reviewer_pane" "$slug-reviewer" "$reviewer"

  cat > "$state/pair.env.new" <<EOF
issue='$issue'
clone='$clone'
seed='$seed'
base='$base'
tab='$tab'
writer_pane='$writer_pane'
reviewer_pane='$reviewer_pane'
writer='$writer'
reviewer='$reviewer'
max_rounds='$max_rounds'
EOF
  mv -f "$state/pair.env.new" "$state/pair.env"

  echo "tab=$tab"
  echo "writer_pane=$writer_pane"
  echo "reviewer_pane=$reviewer_pane"
  echo "clone=$clone"
  echo "base=$base"
  echo "writer=$writer"
  echo "reviewer=$reviewer"
  if [ "$reopened" = 1 ]; then
    # The agents are new and remember nothing; the files carry the history.
    echo "reopened=1"
    pair_status | tail -1
  else
    write_round
  fi
}

case "$command" in
  open) open_pair ;;
  write) write_round ;;
  review) review_round ;;
  say) say_to ;;
  status) pair_status ;;
esac
