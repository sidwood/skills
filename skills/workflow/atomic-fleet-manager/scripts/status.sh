#!/usr/bin/env bash
# List every agent tab in a Herdr workspace except the caller's own: an
# Atomic pane, a composer-grok pane, the QA agent, and any other agent
# whatever its tab is called (a one-off reviewer started by hand). Each row
# has the tab label, a pane, the Herdr agent status and a progress line.
set -euo pipefail

workspace="${1:-${HERDR_WORKSPACE_ID:-}}"
[ "${HERDR_ENV:-}" = 1 ] || { echo "Error: not running inside a Herdr pane." >&2; exit 1; }
[ -n "$workspace" ] || { echo "Usage: status.sh [WORKSPACE_ID]" >&2; exit 2; }

tabs="$(herdr tab list --workspace "$workspace")"
herdr pane list --workspace "$workspace" | TABS="$tabs" python3 -c '
import json, os, sys
labels = {t["tab_id"]: t["label"] for t in json.loads(os.environ["TABS"])["result"]["tabs"]}
for p in json.load(sys.stdin)["result"]["panes"]:
    label = labels.get(p["tab_id"], "?")
    status = p.get("agent_status") or "unknown"
    # A composer-grok pane loses its Herdr agent when the driver exits, so
    # recognize it by its state directory and read the outcome from there.
    state = os.path.join(p.get("cwd") or "", ".atomic", "composer-grok")
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
' | while IFS=$'\t' read -r pane label status progress; do
  if [ "$progress" = "-" ]; then
    screen="$(herdr pane read "$pane" 2>/dev/null || true)"
    progress="$(printf '%s\n' "$screen" | grep -Eo '([a-z-]+ · (single|chain|parallel)|composer-grok) · [^│]*' | tail -1 | sed 's/ *$//' || true)"
  fi
  [ "$progress" != "~" ] || progress="agent, no run"
  printf '%s\t%s\t%s\t%s\n' "$label" "$pane" "$status" "${progress:-no run shown}"
done
