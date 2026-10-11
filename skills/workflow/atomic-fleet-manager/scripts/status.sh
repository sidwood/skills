#!/usr/bin/env bash
# List every agent tab in a Herdr workspace except the caller's own: an
# Atomic pane, a composer-grok pane, a Cursor pair (writer and reviewer
# panes in one tab, shown as one row), the QA agent, and any other agent
# whatever its tab is called (a one-off reviewer started by hand). Each row
# has the tab label, a pane, the Herdr agent status and a progress line.
set -euo pipefail

workspace="${1:-${HERDR_WORKSPACE_ID:-}}"
[ "${HERDR_ENV:-}" = 1 ] || { echo "Error: not running inside a Herdr pane." >&2; exit 1; }
[ -n "$workspace" ] || { echo "Usage: status.sh [WORKSPACE_ID]" >&2; exit 2; }

tabs="$(herdr tab list --workspace "$workspace")"
herdr pane list --workspace "$workspace" | TABS="$tabs" python3 -c '
import glob, json, os, re, sys
labels = {t["tab_id"]: t["label"] for t in json.loads(os.environ["TABS"])["result"]["tabs"]}
pairs = {}
for p in json.load(sys.stdin)["result"]["panes"]:
    label = labels.get(p["tab_id"], "?")
    status = p.get("agent_status") or "unknown"
    cwd = p.get("cwd") or ""
    if os.path.isfile(os.path.join(cwd, ".atomic", "pair", "pair.env")):
        pairs.setdefault(p["tab_id"], []).append(p)
        continue
    # A composer-grok pane loses its Herdr agent when the driver exits, so
    # recognize it by its state directory and read the outcome from there.
    state = os.path.join(cwd, ".atomic", "composer-grok")
    harness = os.path.isdir(state)
    if harness:
        result = os.path.join(state, "result.md")
        if os.path.isfile(result):
            outcome = next((l for l in open(result) if l.startswith("- Outcome:")), "")
            status = "done" if "approved in round" in outcome else "blocked"
        elif status in ("unknown", "idle"):
            status = "working"
    if p.get("agent") == "atomic" or harness:
        print(p["pane_id"], label, status, "-", sep="\t")
    elif (p.get("agent") or label == "QA") and p["pane_id"] != os.environ.get("HERDR_PANE_ID"):
        # Any other agent is listed too, whatever its tab is called, so the
        # watcher wakes when it stops. It has no Atomic run to read: only its
        # agent status counts. The pane this script runs in is left out.
        print(p["pane_id"], label, status, "~", sep="\t")

# A pair is one row: working while either agent works, blocked when an agent
# has left its pane, at rest when both have stopped, which is the fleet
# manager'"'"'s cue to send the next prompt.
for tab, members in pairs.items():
    state = os.path.join(members[0]["cwd"], ".atomic", "pair")
    env = {}
    for line in open(os.path.join(state, "pair.env")):
        key, _, value = line.strip().partition("=")
        env[key] = value.strip(chr(39))
    roles = {env.get("writer_pane"): "writer", env.get("reviewer_pane"): "reviewer"}
    states = {}
    for m in members:
        role = roles.get(m["pane_id"])
        if role:
            states[role] = (m.get("agent_status") or "unknown") if m.get("agent") == "cursor" else "gone"
    for role in ("writer", "reviewer"):
        states.setdefault(role, "gone")
    rounds = len(glob.glob(os.path.join(state, "round-*-writer-prompt.md")))
    gone = [r for r, s in states.items() if s == "gone"]
    busy = [r for r, s in states.items() if s == "working"]
    if gone:
        status, detail = "blocked", gone[0] + " has left its pane"
    elif "blocked" in states.values():
        status, detail = "blocked", "an agent is waiting for input"
    elif busy:
        status, detail = "working", busy[0] + " working"
    else:
        status = "done" if "done" in states.values() else "idle"
        detail = "at rest"
        review = os.path.join(state, "round-%d-review.md" % rounds)
        if os.path.isfile(review):
            found = re.findall(r"VERDICT: (APPROVED|CHANGES_REQUESTED)", open(review).read())
            detail += " · " + (found[-1].lower().replace("_", " ") if found else "no verdict")
        elif os.path.isfile(os.path.join(state, "round-%d-review-prompt.md" % rounds)):
            detail += " · no review file"
        elif os.path.isfile(os.path.join(state, "round-%d-writer.md" % rounds)):
            detail += " · ready for review"
        else:
            detail += " · no writer report"
    progress = "pair · round %d/%s · %s" % (rounds, env.get("max_rounds", "3"), detail)
    print(env.get("writer_pane") or members[0]["pane_id"], labels.get(tab, "?"), status, progress, sep="\t")
' | while IFS=$'\t' read -r pane label status progress; do
  if [ "$progress" = "-" ]; then
    screen="$(herdr pane read "$pane" 2>/dev/null || true)"
    progress="$(printf '%s\n' "$screen" | grep -Eo '([a-z-]+ · (single|chain|parallel)|composer-grok) · [^│]*' | tail -1 | sed 's/ *$//' || true)"
  fi
  [ "$progress" != "~" ] || progress="agent, no run"
  printf '%s\t%s\t%s\t%s\n' "$label" "$pane" "$status" "${progress:-no run shown}"
done
