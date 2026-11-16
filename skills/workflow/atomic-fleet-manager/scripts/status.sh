#!/usr/bin/env bash
# List every agent terminal of the fleet except the caller's own: an Atomic
# harness, a composer-grok harness, a pair (writer and reviewer shown
# as one row), the QA agent, and any other agent in the fleet's space
# whatever it is called (a one-off reviewer, a seat opened by hand). Each row
# has the name, the hc address, the agent status and a progress line.
#
#   status.sh [SPACE_ID]
#
# The fleet is every terminal whose herdr.space label is the space or whose
# fleet.project label is the project, on any machine (see fleet-hc.sh). The
# space defaults to the caller's own; FLEET_PROJECT and FLEET_SPACE override.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=fleet-hc.sh
. "$here/fleet-hc.sh"
fleet_need_hc

space="${1:-$(fleet_space)}"
[ -n "$space" ] || { echo "Usage: status.sh [SPACE_ID] (or run it inside an hc terminal of the fleet)" >&2; exit 2; }

launch_log="${XDG_STATE_HOME:-$HOME/.local/state}/atomic-fleet/launched.tsv"
fleet_snapshot "$space" | SELF="${HC_TERMINAL_ID:-}" python3 -c '
import glob, os, re, sys
pairs = {}
for line in sys.stdin:
    address, name, role, app, state, fleet_state, cwd, where = (line.rstrip("\n").split("\t") + [""] * 8)[:8]
    if address == os.environ["SELF"] or role in ("fm", "helper"):
        continue
    if role in ("pair-writer", "pair-reviewer"):
        pairs.setdefault(name, []).append((address, role, app, state, cwd))
        continue
    status = state
    if role == "composer-grok":
        # The driver labels its own state; a local clone also holds the
        # outcome once it has finished.
        status = fleet_state or ("working" if state in ("unknown", "idle") else state)
        result = os.path.join(cwd, ".atomic", "composer-grok", "result.md")
        if os.path.isfile(result):
            outcome = next((l for l in open(result) if l.startswith("- Outcome:")), "")
            status = "done" if "approved in round" in outcome else "blocked"
        print(address, name, status, "-", sep="\t")
    elif app == "atomic" or role == "harness":
        print(address, name, status, "-", sep="\t")
    elif app != "none" or role == "qa":
        # Any other agent is listed too, so the watcher wakes when it stops.
        # It has no Atomic run to read: only its agent status counts.
        print(address, name, status, "~", sep="\t")

# A pair is one row: working while either agent works, blocked when an agent
# has left its terminal, at rest when both have stopped, which is the fleet
# manager'"'"'s cue to send the next prompt. Its round files are read when its
# clone is on this machine.
for name, members in pairs.items():
    states = {}
    for address, role, app, state, cwd in members:
        # A live terminal whose agent reports no hc status is still there.
        # The Cursor agent reports none, and treating that as gone marks a
        # working pair "has left its terminal". gone is only a role the
        # snapshot does not contain.
        key = role.split("-")[1]
        if app == "none" and state in ("unknown", "none", ""):
            states[key] = "unreported"
        else:
            states[key] = state
    for role in ("writer", "reviewer"):
        states.setdefault(role, "gone")
    writer = next((m for m in members if m[1] == "pair-writer"), members[0])
    pair_dir = os.path.join(writer[4], ".atomic", "pair")
    env = {}
    if os.path.isfile(os.path.join(pair_dir, "pair.env")):
        for line in open(os.path.join(pair_dir, "pair.env")):
            key, _, value = line.strip().partition("=")
            env[key] = value.strip(chr(39))
    rounds = len(glob.glob(os.path.join(pair_dir, "round-*-writer-prompt.md")))
    gone = [r for r, s in states.items() if s == "gone"]
    busy = [r for r, s in states.items() if s == "working"]
    if gone:
        status, detail = "blocked", gone[0] + " has left its terminal"
    elif "blocked" in states.values():
        status, detail = "blocked", "an agent is waiting for input"
    elif busy:
        status, detail = "working", busy[0] + " working"
    elif set(states.values()) == {"unreported"}:
        status, detail = "idle", "no status reported"
    else:
        status = "done" if "done" in states.values() else "idle"
        detail = "at rest"
        review = os.path.join(pair_dir, "round-%d-review.md" % rounds)
        if os.path.isfile(review):
            found = re.findall(r"VERDICT: (APPROVED|CHANGES_REQUESTED)", open(review).read())
            detail += " · " + (found[-1].lower().replace("_", " ") if found else "no verdict")
        elif os.path.isfile(os.path.join(pair_dir, "round-%d-review-prompt.md" % rounds)):
            detail += " · no review file"
        elif os.path.isfile(os.path.join(pair_dir, "round-%d-writer.md" % rounds)):
            detail += " · ready for review"
        else:
            detail += " · no writer report"
    progress = "pair · round %d/%s · %s" % (rounds, env.get("max_rounds", "3"), detail)
    print(writer[0], name, status, progress, sep="\t")
' | while IFS=$'\t' read -r address label status progress; do
  if [ "$progress" = "-" ]; then
    screen="$(fleet_read "$address" || true)"
    progress="$(printf '%s\n' "$screen" | grep -Eo '([a-z-]+ · (single|chain|parallel)|composer-grok) · [^│]*' | tail -1 | sed 's/ *$//' || true)"
    # A run that Atomic holds paused after a failed stage, or one that was
    # quit, is stopped work in a terminal that looks at rest. Report it
    # blocked so the watcher fires and it is resumed.
    held="$(printf '%s\n' "$screen" | grep -Eo 'BACKGROUND .*[0-9]+ (paused|quit)' | grep -Eo '(paused|quit)' | tail -1 || true)"
    if [ -n "$held" ] && [ "$label" != QA ]; then
      status=blocked
      progress="run $held, resume it · ${progress:-no run shown}"
    fi
    # A session can start a run of its own when the one it was launched with
    # ends (a repair pass after a round limit). It never comes to rest, so
    # compare the run it shows with the one recorded at launch. To accept the
    # new run, append a line for it to the launch log.
    shown="$(printf '%s\n' "$screen" | fleet_chain_run || true)"
    launched="$(awk -F'\t' -v t="$address" '$1 == t { id = $3 } END { print id }' "$launch_log" 2>/dev/null || true)"
    if [ -n "$shown" ] && [ -n "$launched" ] && [ "$shown" != "$launched" ] && [ "$label" != QA ] && [ "$status" != blocked ]; then
      status=blocked
      progress="unexpected run ${shown%%-*}, launched with ${launched%%-*} · ${progress:-no run shown}"
    fi
  fi
  [ "$progress" != "~" ] || progress="agent, no run"
  printf '%s\t%s\t%s\t%s\n' "$label" "$address" "$status" "${progress:-no run shown}"
done
