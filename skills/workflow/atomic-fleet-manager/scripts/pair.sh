#!/usr/bin/env bash
# A writer and a reviewer in one GUI tab, driven by the fleet manager one
# prompt at a time. The script opens one Herdr pane, splits it down, and
# runs one agent in each half. Each is an hc terminal named for the issue
# (fleet.name) with the role pair-writer or pair-reviewer. Every prompt is
# typed into the agent's terminal and is short enough to be read there in
# full; it names the brief and the standing rules, which are files in the
# clone under .atomic/pair/ beside a copy of each prompt and the agents'
# reports.
#
# --writer and --reviewer take LAUNCHER:MODEL, a bare model name (that means
# the Cursor agent), or a launcher whose model is fixed. claude-work spends
# the owner's own Claude account and is never a default: it runs only when
# the command names it. Homebrew's `agent` is Grok Build, so Cursor is the
# binary at PAIR_CURSOR_AGENT (default: ~/.local/bin/agent).
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pair.sh open   --issue ID --brief FILE [options]
       pair.sh write  --issue ID [--note TEXT] [--max-rounds N]
       pair.sh review --issue ID [--note TEXT]
       pair.sh say    --issue ID --to writer|reviewer --note TEXT
       pair.sh status --issue ID

  open     Make a branch clone, open a GUI tab named for the issue with the
           writer beside the reviewer, and send the writer round 1.
  write    Send the writer the next round: the reviewer's findings.
  review   Send the reviewer the current round's work.
  say      Answer an agent inside the current round, without starting a
           new one: when it stopped to ask, or stopped before its report.
  status   One line: round, agent states, verdict, and what comes next.

  --issue ID         Tracker issue identifier, also the terminals' name (TUS-36)
  --brief FILE       Work definition written from the tracker issue (open)
  --note TEXT        The fleet manager's own words, appended to the prompt
  --to ROLE          With say: writer or reviewer
  --clone DIR        The pair's clone, when its terminals cannot be found.
                     With open: a pair's clone whose agents are gone (new
                     agents, same round files), or with --brief another
                     harness's unfinished clone to start a pair on
  --seed DIR         Seed checkout to clone from (default: current directory)
  --space ID         The fleet's GUI space (default: the caller's own;
                     --workspace is the old name)
  --writer SPEC      Who writes (default: composer-2.5, the Cursor agent).
                     cursor:MODEL, claude-work:MODEL, claude-glm, grok,
                     grok:MODEL, or a bare model name (Cursor).
  --reviewer SPEC    Who reviews (default: grok-4.7-xhigh, the Cursor agent).
                     Same forms as --writer.
  --max-rounds N     Writer rounds allowed (default: 3)
  --max-pairs N      How many pairs may be open at once (default: 2, or
                     FLEET_MAX_PAIRS). The load check is separate.
  --max-workers N    Test workers an agent may use (default: 4)
  --max-load N       open refuses at or above this 1-minute load (default: 12)

The writer and the reviewer must be different model families, compared
across launchers: cursor:grok-4.7-xhigh and grok are the same family.
claude-work is never chosen unless the command names it. QA is not a pane
of this tab.
USAGE
}

fail() { echo "Error: $1" >&2; exit 1; }

command="${1:-}"
[ $# -gt 0 ] && shift
issue="" brief="" note="" to="" clone="" seed="$PWD" workspace=""
writer="" reviewer="" max_rounds="" max_pairs="${FLEET_MAX_PAIRS:-2}"
max_workers="${FLEET_MAX_WORKERS:-4}" max_load=12
CURSOR_AGENT="${PAIR_CURSOR_AGENT:-$HOME/.local/bin/agent}"
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --brief) brief="$2"; shift 2 ;;
    --note) note="$2"; shift 2 ;;
    --to) to="$2"; shift 2 ;;
    --clone) clone="$2"; shift 2 ;;
    --seed) seed="$2"; shift 2 ;;
    --space|--workspace) workspace="$2"; shift 2 ;;
    --writer) writer="$2"; shift 2 ;;
    --reviewer) reviewer="$2"; shift 2 ;;
    --max-rounds) max_rounds="$2"; shift 2 ;;
    --max-pairs) max_pairs="$2"; shift 2 ;;
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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$(cd "$(dirname "$0")" && pwd)/fleet-hc.sh"
fleet_need_hc
[ -n "$issue" ] || fail "--issue is required."
[ -n "$workspace" ] || workspace="$(fleet_space)"
[ -n "$workspace" ] || fail "no GUI space: run inside an hc terminal of the fleet or pass --space."

# The agent's status as hc reports it (Cursor's agent reports its own), or
# gone when its terminal has ended.
pane_state() { # terminal -> working | idle | done | blocked | error | unknown | gone
  local state
  state="$(fleet_state "$1")"
  echo "${state#* }"
}

# Issues that already have a pair open in this space, other than this one.
other_pairs() {
  fleet_snapshot "$workspace" | awk -F'\t' -v issue="$issue" '$3 == "pair-writer" && $2 != issue { print $2 }' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# The clone of the pair named for the issue: its writer's folder.
find_clone() {
  fleet_snapshot "$workspace" | awk -F'\t' -v issue="$issue" '$3 == "pair-writer" && $2 == issue { print $7; exit }'
}

load_pair() {
  [ -n "$clone" ] || clone="$(find_clone)"
  [ -n "$clone" ] || fail "no pair named $issue in space $workspace; pass --clone."
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

# Type the prompt file into the agent's terminal.
# hc send succeeding is delivery. Some agents, the Cursor reviewer included,
# never report `working`, and waiting for that word failed every review.
send() { # terminal file
  local ack tries=0 state
  ack="$(hc send "$1" "$(cat "$2")" 2>&1)" || fail "could not prompt terminal $1: $ack"
  case "$ack" in *'"error"'*) fail "could not prompt terminal $1: $ack" ;; esac
  while [ "$tries" -lt 5 ]; do
    state="$(pane_state "$1")"
    case "$state" in
      working) return 0 ;;
      error) fail "terminal $1 reported an error after the prompt; read it (hc read $1)." ;;
      unknown|none) return 0 ;;
    esac
    sleep 2
    tries=$((tries + 1))
  done
}

# SPEC is launcher:model, a bare model name (Cursor), or a launcher with a
# fixed model. Sets seat_launcher and seat_model. claude-work is not a
# default: a bare name is the Cursor agent.
parse_seat() { # spec
  local spec="$1"
  case "$spec" in
    cursor:*) seat_launcher=cursor; seat_model="${spec#cursor:}" ;;
    claude-work:*) seat_launcher=claude-work; seat_model="${spec#claude-work:}" ;;
    claude-glm:*) seat_launcher=claude-glm; seat_model="${spec#claude-glm:}" ;;
    claude-glm) seat_launcher=claude-glm; seat_model='glm-5.3[1m]' ;;
    grok:*) seat_launcher=grok; seat_model="${spec#grok:}" ;;
    grok) seat_launcher=grok; seat_model=grok-4.7 ;;
    *:*) fail "unknown launcher in '$spec'." ;;
    *) seat_launcher=cursor; seat_model="$spec" ;;
  esac
  [ -n "$seat_model" ] || fail "'$spec' needs a model."
}

# Family compared across launchers. cursor:grok-4.7-xhigh and grok match.
model_family() { # model launcher
  local name launcher="$2"
  name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$launcher" in
    claude-glm) printf '%s\n' glm; return ;;
  esac
  case "$name" in
    grok|grok-*) printf '%s\n' grok ;;
    composer|composer-*) printf '%s\n' composer ;;
    glm|glm-*) printf '%s\n' glm ;;
    claude*|opus*|sonnet*|fable*|haiku*) printf '%s\n' claude ;;
    *) printf '%s\n' "${name%%-*}" ;;
  esac
}

# The command that starts this launcher. Sets seat_argv.
#   cursor       ~/.local/bin/agent --model MODEL -f
#                ready: "Plan, search, build" or "Add a follow-up"
#                trust: "Trust this workspace" -> key a
#                prompt: hc send (folds past about 500 characters)
#   claude-work  CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions --model MODEL
#   claude-glm   CLAUDE_CONFIG_DIR=~/.claude-glm and the unknown-model override,
#                claude --dangerously-skip-permissions --model "glm-5.3[1m]"
#                ready: a line that is ❯
#                trust: the chooser defaults to "No, exit" -> down, then enter
#                prompt: hc send
#   grok         grok --model MODEL --trust --permission-mode bypassPermissions
#                ready: a line that is ❯
#                trust: --trust, else "Trust this folder?" -> enter
#                prompt: hc send
build_seat() { # launcher model
  local launcher="$1" model="$2" workers="VITEST_MAX_WORKERS=$max_workers"
  case "$launcher" in
    cursor)
      [ -x "$CURSOR_AGENT" ] || fail "The Cursor agent is not at $CURSOR_AGENT. Homebrew's agent is Grok Build; do not use it."
      "$CURSOR_AGENT" status 2>/dev/null | grep -q "Logged in" || fail "The Cursor agent at $CURSOR_AGENT is not logged in."
      seat_argv=(env "$workers" "$CURSOR_AGENT" --model "$model" -f)
      ;;
    claude-work|claude-glm)
      command -v claude >/dev/null || fail "claude is not on PATH."
      if [ "$launcher" = claude-work ]; then
        seat_argv=(env "CLAUDE_CONFIG_DIR=$HOME/.claude-work" "$workers" claude --dangerously-skip-permissions --model "$model")
      else
        seat_argv=(env "CLAUDE_CONFIG_DIR=$HOME/.claude-glm" CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 "$workers" claude --dangerously-skip-permissions --model "$model")
      fi
      ;;
    grok)
      command -v grok >/dev/null || fail "grok is not on PATH."
      if grok models 2>&1 | grep -q "not authenticated"; then
        fail "grok is not logged in."
      fi
      seat_argv=(env "$workers" grok --model "$model" --trust --permission-mode bypassPermissions)
      ;;
    *) fail "unknown launcher '$launcher'." ;;
  esac
}

seat_ready() { # launcher screen
  local launcher="$1" screen="$2"
  case "$launcher" in
    cursor)
      case "$screen" in
        *"Plan, search, build"*|*"Add a follow-up"*) return 0 ;;
      esac
      ;;
    *)
      if printf '%s\n' "$screen" | grep -Eq '^[[:space:]]*❯[[:space:]]*$'; then
        return 0
      fi
      ;;
  esac
  return 1
}

# Wait until the agent can take a prompt, accepting its trust chooser once.
wait_ready() { # terminal launcher role
  local terminal="$1" launcher="$2" role="$3" screen trusted=0 tries=0
  while [ "$tries" -lt 45 ]; do
    screen="$(fleet_read "$terminal" 60 || true)"
    # Accept a trust chooser before treating the screen as ready. Claude's
    # chooser defaults to "No, exit", so it needs Down, then Enter.
    if [ "$trusted" = 0 ]; then
      case "$launcher" in
        cursor)
          case "$screen" in
            *"Trust this workspace"*) hc keys "$terminal" a >/dev/null || true; trusted=1 ;;
          esac
          ;;
        grok)
          case "$screen" in
            *"Trust this folder?"*) hc keys "$terminal" enter >/dev/null || true; trusted=1 ;;
          esac
          ;;
        *)
          case "$screen" in
            *"No, exit"*|*"quick safety check"*) hc keys "$terminal" down enter >/dev/null || true; trusted=1 ;;
          esac
          ;;
      esac
      if [ "$trusted" = 1 ]; then
        sleep 2
        tries=$((tries + 1))
        continue
      fi
    fi
    if seat_ready "$launcher" "$screen"; then return 0; fi
    sleep 2
    tries=$((tries + 1))
  done
  fail "the $role did not reach its prompt in terminal $terminal."
}

wait_for_pane() { # terminal
  local terminal="$1" pane="" tries=0
  while [ -z "$pane" ] && [ "$tries" -lt 15 ]; do
    pane="$(fleet_pane_of "$terminal")"
    [ -n "$pane" ] || { sleep 1; tries=$((tries + 1)); }
  done
  printf '%s' "$pane"
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
- Follow \`AGENTS.md\` for how to run commands and for commit messages: an imperative subject of at most 50 characters, a body that says why, and no tracker issue number anywhere in the message.
- A commit message carries no trailer of any kind. No Co-Authored-By, no Co-authored-by, no Signed-off-by, no attribution. Claude adds Co-Authored-By unless you leave it out; do not add one. The commit hook rejects every trailer. Never pass \`--no-verify\`. If a commit fails for a trailer, rewrite the message without it and commit again.
- Run the checks \`AGENTS.md\` names for the code you touch and fix what fails. This machine runs several agents at once: run suites one at a time and give any test runner at most $max_workers workers.
- Before stating a command, path, port or name in code or documentation, confirm it exists in this repository. When you correct a mistake, search for the same mistake elsewhere and correct every instance the issue covers.
- In a later round the reviewer's findings are in \`.atomic/pair/round-N-review.md\`. Address every finding, or say precisely why one is wrong.$gate_rule

## Finishing a round

Commit everything that belongs in the change. Then write \`.atomic/pair/round-N-writer.md\`, where N is the round (the file is not committed): what you changed and why, or what you did about each finding by its number; each check you ran with its result; the gate's last line if you ran it; and anything you could not do. Then stop.
EOF
  cat > "$state/reviewer-rules.md" <<EOF
# Rules for the reviewer of $issue

A different model wrote this work in the pane above yours. Do not edit, stage, commit or stash anything: the only file you write is your report.

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
7. Each commit message has a body that says why, names no tracker issue, and carries no trailer (no Co-Authored-By and no other trailer).

## Report

Write \`.atomic/pair/round-N-review.md\`: numbered findings, most serious first, each with a severity from P0 to P3, the file and line, and the observable problem; or say there are none. Its last line must be exactly \`VERDICT: APPROVED\` or \`VERDICT: CHANGES_REQUESTED\`. Then stop.
EOF
}

# Type the prompt file into its terminal; say so when it is too long to be shown.
deliver() { # role pane file round
  local chars
  [ -z "$note" ] || printf ' From the fleet manager: %s' "$note" >> "$3"
  chars="$(wc -m < "$3" | tr -d ' ')"
  send "$2" "$3"
  echo "sent=$1 round=$4 terminal=$2 chars=$chars prompt=$3"
  [ "$chars" -le 500 ] || echo "note=this prompt is over 500 characters, so the terminal shows it folded as [Pasted text]; the file has it in full."
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
    fail "the writer left no report for round $round (.atomic/pair/round-$round-writer.md). Read terminal $writer_pane."
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
  if [ "$w" = gone ] || [ "$r" = gone ]; then next="reopen (an agent has left its terminal): pair.sh open --issue $issue --clone $clone"
  elif [ "$w" = working ] || [ "$r" = working ]; then next="wait"
  elif [ "$round" = 0 ]; then next="write"
  elif [ ! -f "$state/round-$round-writer.md" ]; then next="read the writer's terminal $writer_pane (no report for round $round), then answer it: pair.sh say --to writer --note ..."
  elif [ ! -f "$state/round-$round-review-prompt.md" ]; then next="review"
  elif [ -z "$verdict" ]; then next="read the reviewer's terminal $reviewer_pane (no verdict for round $round), then answer it: pair.sh say --to reviewer --note ..."
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
  # Each handoff waits for the fleet manager, so the number of open pairs
  # is capped. The manager sets it with --max-pairs or FLEET_MAX_PAIRS.
  local open_pairs open_count
  open_pairs="$(other_pairs)"
  open_count="$(printf '%s' "$open_pairs" | wc -w | tr -d ' ')"
  [ "$open_count" -lt "$max_pairs" ] || fail "$open_count pairs are already open ($open_pairs), and the limit is $max_pairs. Set --max-pairs or FLEET_MAX_PAIRS, or give $issue to an Atomic writer from its tier label."

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
    awk -v load="$(fleet_load)" -v max="$max_load" 'BEGIN { exit !(load < max) }' ||
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
  # One model family never reviews its own work, whichever launcher it uses.
  parse_seat "$writer"
  writer_launcher=$seat_launcher
  writer_model=$seat_model
  parse_seat "$reviewer"
  reviewer_launcher=$seat_launcher
  reviewer_model=$seat_model
  local writer_family reviewer_family
  writer_family="$(model_family "$writer_model" "$writer_launcher")"
  reviewer_family="$(model_family "$reviewer_model" "$reviewer_launcher")"
  [ "$writer_family" != "$reviewer_family" ] || fail "writer '$writer' and reviewer '$reviewer' are the same model family ($writer_family)."

  local tab="" writer_pane="" reviewer_pane="" pane="" argv_json="" result="" terminal=""
  build_seat "$writer_launcher" "$writer_model"
  writer_pane="$(fleet_open "$issue" pair-writer "$clone" --space "$workspace" -- "${seat_argv[@]}")" ||
    fail "could not start the writer for $issue."
  [ -n "$writer_pane" ] || fail "could not start the writer for $issue."
  fleet_name_tab "$writer_pane" "$issue"
  # The reviewer is the other half of this pane, not a child of the manager
  # and not a second tab. With no GUI pane to split, it gets a tab of its own.
  build_seat "$reviewer_launcher" "$reviewer_model"
  pane="$(wait_for_pane "$writer_pane")"
  if [ -n "$pane" ] && command -v herdr-app >/dev/null; then
    argv_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${seat_argv[@]}")"
    result="$(herdr-app "do" pane.split --direction down --pane "$pane" --argv "$argv_json" 2>&1)" || true
    terminal="$(printf '%s' "$result" | python3 -c 'import json,sys
raw = sys.stdin.read()
start = raw.find("{")
if start < 0:
    sys.exit(1)
obj = json.loads(raw[start:])
if obj.get("error"):
    sys.exit(1)
sys.stdout.write(obj.get("terminal") or "")')" ||
      fail "could not split pane $pane for the reviewer ($result). The writer is terminal $writer_pane."
    [ -n "$terminal" ] || fail "pane split did not return a terminal ($result). The writer is terminal $writer_pane."
    hc label "$terminal" "fleet.name=$issue" fleet.role=pair-reviewer \
      "fleet.project=$(fleet_project "$workspace")" "herdr.space=$workspace" ||
      fail "could not label reviewer terminal $terminal."
    reviewer_pane="$terminal"
    tab="$(fleet_tab_of "$writer_pane")"
  else
    reviewer_pane="$(fleet_open "$issue" pair-reviewer "$clone" --space "$workspace" -- "${seat_argv[@]}")" ||
      fail "could not start the reviewer for $issue. The writer is terminal $writer_pane."
    [ -n "$reviewer_pane" ] || fail "could not start the reviewer for $issue. The writer is terminal $writer_pane."
    fleet_name_tab "$reviewer_pane" "$issue"
    tab="$(fleet_tab_of "$reviewer_pane")"
  fi
  wait_ready "$writer_pane" "$writer_launcher" writer
  wait_ready "$reviewer_pane" "$reviewer_launcher" reviewer

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
writer_launcher='$writer_launcher'
writer_model='$writer_model'
reviewer_launcher='$reviewer_launcher'
reviewer_model='$reviewer_model'
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
