#!/usr/bin/env bash
# Run one Fleet Manager Assistant: a helper agent in a Herdr tab of its own,
# labelled FMA-<n>, so Sid can watch it work. Every helper the fleet manager
# starts outside Claude Code's own subagents runs this way (Sid, 2026-10-11):
# pre-launch reads, plans, tracker edits.
#
#   fma.sh "<what it does>" <prompt file> [model] [workspace]
#
# The tab runs Atomic in print mode (interactive Atomic 0.9.32 leaves the
# codemode tool off, so it cannot reach Linear) and shows each tool call and
# message as it happens through fma-view.py. The agent's last message is
# saved beside the prompt as fma-<n>.reply.md and the tab's text as
# fma-<n>.out; then the tab closes and the reply is printed. Exit 1 if the
# run never finished within FMA_TIMEOUT seconds (default 3 h); the tab is
# then left open to read.
set -uo pipefail
what="$(printf '%s' "$1" | tr -d "\"'\\\`\$")" prompt="$2" model="${3:-openai/gpt-6.1-sol:xhigh}" workspace="${4:-w15}"
seed=/Users/sidwood/code/casefilecrafter
fleet="$seed/.atomic/fleet"
here="$fleet/fm-scripts"
timeout="${FMA_TIMEOUT:-10800}"
[ -s "$prompt" ] || { echo "fma: no prompt file at $prompt" >&2; exit 2; }
prompt="$(cd "$(dirname "$prompt")" && pwd)/$(basename "$prompt")"
dir="$(dirname "$prompt")"

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
  echo "You are $label, a Fleet Manager Assistant for the Casefile Crafter fleet manager. Do exactly what follows. Linear is reached through your codemode tool: a codemode script finds its tools with searchTools() (get_issue, list_comments, list_issues, save_issue, save_comment) and calls them. Never read credential files. Your last message is your reply to the fleet manager. This whole task is also in the file $full: if your context is ever compacted or you lose track of the task, read that file again before you go on. Write any output file early and add to it section by section, so work survives a compaction."
  echo
  cat "$prompt"
} > "$full"

field() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k]
print(d if d is not None else "")' "$1"; }

created="$(herdr tab create --workspace "$workspace" --cwd "$seed" --label "$label" --no-focus)"
tab="$(printf '%s' "$created" | field result.tab.tab_id)"
pane="$(printf '%s' "$created" | field result.root_pane.pane_id)"
echo "$label tab=$tab pane=$pane model=$model"
sleep 2
herdr pane run "$pane" "echo '$label: $what'; atomic -ns --no-session --model $model --mode json -p \"\$(cat '$full')\" </dev/null 2>'$dir/fma-$n.err' | python3 '$here/fma-view.py' '$reply'; touch '$done_marker'" >/dev/null

waited=0
until [ -f "$done_marker" ]; do
  [ "$waited" -lt "$timeout" ] || { echo "$label: still working after ${timeout}s; tab $tab left open"; exit 1; }
  sleep 10; waited=$((waited + 10))
done
herdr pane read --source recent-unwrapped --lines 2000 "$pane" > "$dir/fma-$n.out" 2>/dev/null
echo "$(date '+%Y-%m-%d %H:%M') $label done ($reply)" >> "$fleet/fma.log"
herdr tab close "$tab" >/dev/null 2>&1
echo "$label DONE $(date '+%H:%M') reply=$reply"
if [ -s "$reply" ] && grep -q . "$reply"; then cat "$reply"; else echo "(no reply; last lines of the tab)"; grep -vE '^\s*$' "$dir/fma-$n.out" | tail -20; tail -c 400 "$dir/fma-$n.err" 2>/dev/null; fi
