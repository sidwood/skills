#!/usr/bin/env bash
# Run one Fleet Manager Assistant: a helper agent in an hc terminal of its
# own, in a GUI tab named FMA-<n>, so the user can watch it work. Every
# helper the fleet manager starts outside its own subagents runs this way:
# pre-launch reads, plans, tracker edits.
#
#   fma.sh "<what it does>" <prompt file> [model] [space id]
#
# Copy it into the project's fleet folder beside fma-view.py and set the
# seed and project lines below. The space defaults to the fleet manager's
# own (its terminal's herdr.space label).
#
# The terminal runs Atomic in print mode and shows each tool call and
# message as it happens through fma-view.py. The agent's last message is
# saved beside the prompt as fma-<n>.reply.md and the terminal's text as
# fma-<n>.out; then the terminal is removed and the reply is printed. Exit 1
# if the run never finished within FMA_TIMEOUT seconds (default 3 h); the
# terminal is then left open to read.
set -uo pipefail
what="$(printf '%s' "$1" | tr -d "\"'\\\`\$")" prompt="$2" model="${3:-anthropic/claude-sonnet-5-5:xhigh}" space="${4:-}"
seed="${FMA_SEED:-$(git rev-parse --show-toplevel)}"
project="${FMA_PROJECT:-$(basename "$seed")}"
fleet="$seed/.atomic/fleet"
here="$(cd "$(dirname "$0")" && pwd)"
timeout="${FMA_TIMEOUT:-10800}"
[ -s "$prompt" ] || { echo "fma: no prompt file at $prompt" >&2; exit 2; }
prompt="$(cd "$(dirname "$prompt")" && pwd)/$(basename "$prompt")"
dir="$(dirname "$prompt")"

label_of() { hc get "$1" --json 2>/dev/null | python3 -c 'import json,sys
print((json.load(sys.stdin).get("labels") or {}).get(sys.argv[1], ""))' "$2"; }
[ -n "$space" ] || space="$(label_of "${HC_TERMINAL_ID:-}" herdr.space)"
[ -n "$space" ] || { echo "fma: no GUI space; run it in the fleet manager's terminal or pass one" >&2; exit 2; }

# The next number, under a lock so two helpers started at once differ.
lock="$fleet/fma-counter.lock"
until mkdir "$lock" 2>/dev/null; do sleep 1; done
n=$(( $(cat "$fleet/fma-counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$fleet/fma-counter"
rmdir "$lock"
label="FMA-$n"
echo "$(date '+%Y-%m-%d %H:%M') $label $model $what ($prompt)" >> "$fleet/fma.log"

reply="$dir/fma-$n.reply.md" done_marker="$dir/fma-$n.done" full="$dir/fma-$n.prompt.txt"
rm -f "$reply" "$done_marker"
{
  echo "You are $label, a Fleet Manager Assistant for the $project fleet manager. Do exactly what follows. Never read credential files. Your last message is your reply to the fleet manager. This whole task is also in the file $full: if your context is ever compacted or you lose track of the task, read that file again before you go on. Write any output file early and add to it section by section, so work survives a compaction."
  echo
  cat "$prompt"
} > "$full"

pane="$(hc run --bg --json --no-parent --outlive-parent --keep --cwd "$seed" \
  --label "herdr.space=$space" --label "fleet.name=$label" --label fleet.role=helper --label "fleet.project=$project" \
  -- sh -c "echo '$label: $what'; atomic -ns --no-session --model $model --mode json -p \"\$(cat '$full')\" </dev/null 2>'$dir/fma-$n.err' | python3 '$here/fma-view.py' '$reply'; touch '$done_marker'" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
[ -n "$pane" ] || { echo "fma: could not open a terminal for $label" >&2; exit 1; }
echo "$label terminal=$pane model=$model"
# Name its GUI tab; the GUI names a new tab by number. Best effort.
if command -v herdr-app >/dev/null; then
  sleep 2
  tab="$(herdr-app ls 2>/dev/null | python3 -c 'import json,sys
for s in json.load(sys.stdin).get("spaces", []):
    for t in s.get("tabs", []):
        if any(x.get("terminal") == sys.argv[1] for x in t.get("terminals", [])): print(t["id"])' "$pane" || true)"
  [ -z "$tab" ] || herdr-app "do" tab.rename --id "$tab" --name "$label" >/dev/null 2>&1 || true
fi

waited=0
until [ -f "$done_marker" ]; do
  [ "$waited" -lt "$timeout" ] || { echo "$label: still working after ${timeout}s; terminal $pane left open"; exit 1; }
  sleep 10; waited=$((waited + 10))
done
hc read "$pane" --lines 2000 > "$dir/fma-$n.out" 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M') $label done ($reply)" >> "$fleet/fma.log"
hc kill "$pane" >/dev/null 2>&1; hc rm "$pane" >/dev/null 2>&1
echo "$label DONE $(date '+%H:%M') reply=$reply"
if [ -s "$reply" ] && grep -q . "$reply"; then cat "$reply"; else echo "(no reply; last lines of the terminal)"; grep -vE '^\s*$' "$dir/fma-$n.out" | tail -20; tail -c 400 "$dir/fma-$n.err" 2>/dev/null; fi
