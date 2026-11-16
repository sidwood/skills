# shellcheck shell=bash
# Herdr Core helpers shared by the fleet scripts. Source it:
#   . "$(dirname "$0")/fleet-hc.sh"
#
# The fleet lives in one GUI space. Every terminal a script opens carries
# four labels:
#   herdr.space=<space id>   the GUI shows it in that space; on another
#                            machine, in that machine's space of the same id
#   fleet.name=<ISSUE>       how the scripts find it (the GUI rewrites where)
#   fleet.role=<role>        harness, qa, writer, reviewer, pair-writer,
#                            pair-reviewer, composer-grok or helper
#   fleet.project=<name>     the project, wherever the terminal runs
# A terminal opened by hand joins with
#   hc label <t> fleet.name=<NAME> fleet.role=<role> fleet.project=<project>
#
# Settings: FLEET_SPACE (default: the caller's own terminal's space) and
# FLEET_PROJECT (default: the caller's fleet.project label, then the GUI
# name of the space, then the folder's name).

FLEET_HC_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-hc.py"

fleet_need_hc() {
  command -v hc >/dev/null || { echo "Error: hc (Herdr Core) is not on PATH." >&2; exit 1; }
}

fleet_label() { # terminal key
  hc get "$1" --json 2>/dev/null | python3 -c 'import json,sys
print((json.load(sys.stdin).get("labels") or {}).get(sys.argv[1], ""))' "$2" 2>/dev/null || true
}

fleet_space() {
  if [ -n "${FLEET_SPACE:-}" ]; then echo "$FLEET_SPACE"; return; fi
  [ -z "${HC_TERMINAL_ID:-}" ] || fleet_label "$HC_TERMINAL_ID" herdr.space
}

fleet_project() { # [space]
  if [ -n "${FLEET_PROJECT:-}" ]; then echo "$FLEET_PROJECT"; return; fi
  local project="" space="${1:-}"
  [ -z "${HC_TERMINAL_ID:-}" ] || project="$(fleet_label "$HC_TERMINAL_ID" fleet.project)"
  [ -n "$space" ] || space="$(fleet_space)"
  if [ -z "$project" ] && [ -n "$space" ] && command -v herdr-app >/dev/null; then
    project="$(python3 "$FLEET_HC_PY" space-name "$space" 2>/dev/null || true)"
  fi
  [ -n "$project" ] || project="$(basename "$PWD")"
  echo "$project"
}

fleet_state() { # terminal -> "app state", "none unknown" when unreadable
  hc get "$1" --json 2>/dev/null | python3 -c 'import json,sys
t=json.load(sys.stdin); s=t.get("status") or {}
print("none gone" if t.get("state") != "live" else "%s %s" % (s.get("app") or "none", s.get("state") or "unknown"))' 2>/dev/null ||
    echo "none gone"
}

# The screen (lines 0) or the screen with N lines of history.
fleet_read() { hc read "$1" --lines "${2:-0}" 2>/dev/null; }

# The chain run id on a terminal's screen. The BACKGROUND panel's bullet
# line (`● <run id>`) is the run; a stage id printed in the chat is not.
# When that line is missing, the last UUID after BACKGROUND. launch.sh
# records this and status.sh compares it, so the two stay the same.
fleet_chain_run() {
  local uuid_re='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  local screen id
  screen="$(cat)"
  id="$(printf '%s\n' "$screen" | awk '/BACKGROUND/ { seen = 1 } seen && /●/' |
    grep -Eo "$uuid_re" | tail -1 || true)"
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  printf '%s\n' "$screen" | awk '/BACKGROUND/ { seen = 1 } seen' |
    grep -Eo "$uuid_re" | tail -1 || true
}

fleet_send() { hc send "$1" "$2" >/dev/null; }

fleet_close() {
  hc kill "$1" >/dev/null 2>&1 || true
  hc rm "$1" >/dev/null 2>&1 || true
}

# Open a terminal for the fleet and print its address:
#   fleet_open NAME ROLE FOLDER [--on MACHINE] [--tab TAB] [--space ID] -- ARGV...
# It outlives the caller and keeps a shell when its program ends, so its
# screen stays readable. It is never a child of the caller. hc run parents
# a new terminal under the caller unless --no-parent is set, and that child
# shows up inside the manager's pane; that is never used. FLEET_NEST is not
# read, so a leftover setting cannot nest one. --tab puts this terminal in
# the other half of that GUI tab (a reviewer beside its writer). The tab is
# named for the issue or the role, and fleet.name is a real name.
fleet_open() {
  local name="$1" role="$2" dir="$3" on="" tab="" space="" project
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --on) on="$2"; shift 2 ;;
      --tab) tab="$2"; shift 2 ;;
      --space) space="$2"; shift 2 ;;
      --) shift; break ;;
      *) echo "Error: fleet_open: unknown option '$1'." >&2; return 2 ;;
    esac
  done
  [ -n "$space" ] || space="$(fleet_space)"
  [ -n "$space" ] || { echo "Error: no GUI space; run inside an hc terminal of the fleet or set FLEET_SPACE." >&2; return 1; }
  project="$(fleet_project "$space")"
  local opts=(--bg --json --no-parent --outlive-parent --keep --cwd "$dir"
    --label "herdr.space=$space" --label "fleet.name=$name" --label "fleet.role=$role" --label "fleet.project=$project")
  [ -z "$on" ] || opts+=(--on "$on")
  # A remote tab id carries its machine (framework/tb..); the label takes the bare id.
  [ -z "$tab" ] || opts+=(--label "herdr.tab=${tab#*/}")
  hc run "${opts[@]}" -- "$@" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])'
}

# Name the GUI tab holding a terminal. The GUI creates the tab a moment
# after the terminal and names it by number; renaming the tab is what sticks
# (setting where does not). Best effort: no window, no rename. A terminal
# opened into an existing tab (--tab) shares that tab, which already has
# its name. A child of the caller, which these scripts do not create, also
# sits in the caller's tab and must not rename it.
fleet_name_tab() { # terminal name
  command -v herdr-app >/dev/null || return 0
  local tab="" tries=0 own=""
  [ -z "${HC_TERMINAL_ID:-}" ] || own="$(python3 "$FLEET_HC_PY" tab "$HC_TERMINAL_ID" 2>/dev/null || true)"
  if [ -n "${HC_TERMINAL_ID:-}" ] && [ "$(hc get "$1" --json 2>/dev/null | python3 -c 'import json,sys
print(json.load(sys.stdin).get("parent") or "")' 2>/dev/null)" = "$HC_TERMINAL_ID" ]; then return 0; fi
  while [ -z "$tab" ] && [ "$tries" -lt 10 ]; do
    tab="$(python3 "$FLEET_HC_PY" tab "$1" 2>/dev/null || true)"
    [ -n "$tab" ] || { sleep 1; tries=$((tries + 1)); }
  done
  [ -z "$tab" ] || [ "$tab" = "$own" ] || herdr-app 'do' tab.rename --id "$tab" --name "$2" >/dev/null 2>&1 || true
}

# The GUI tab holding a terminal, for fleet_open --tab.
fleet_tab_of() { python3 "$FLEET_HC_PY" tab "$1" 2>/dev/null || true; }

# The GUI pane holding a terminal, for a split.
fleet_pane_of() { python3 "$FLEET_HC_PY" pane "$1" 2>/dev/null || true; }

# Fleet terminals as tab-separated rows (see fleet-hc.py snapshot).
fleet_snapshot() { # [space]
  local space="${1:-$(fleet_space)}"
  python3 "$FLEET_HC_PY" snapshot --space "$space" --project "$(fleet_project "$space")"
}

# The 1-minute load average on this machine.
fleet_load() {
  if [ -r /proc/loadavg ]; then awk '{print $1}' /proc/loadavg; else sysctl -n vm.loadavg | awk '{print $2}'; fi
}

# --- Another machine -------------------------------------------------------
# The skill scripts a remote run needs, copied from this machine on every
# call, so the remote copy of the skill cannot drift from the caller's.
FLEET_REMOTE_SCRIPTS=(fleet-hc.sh fleet-hc.py launch.sh resume.sh status.sh)

# Copy them to MACHINE and print the folder they landed in (absolute).
fleet_push_skill() { # machine
  local machine="$1" here dir file
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  dir=".local/state/atomic-fleet/skill"
  for file in "${FLEET_REMOTE_SCRIPTS[@]}"; do
    hc file write --on "$machine" "$dir/$file" <"$here/$file" >/dev/null || return 1
  done
  hc exec --on "$machine" -- bash -c "chmod +x \"\$HOME/$dir\"/*.sh \"\$HOME/$dir\"/*.py && echo \"\$HOME/$dir\""
}

# Run a bash script on MACHINE with the usual tool folders on PATH.
fleet_remote() { # machine script [timeout]
  hc exec --on "$1" --timeout "${3:-120}" -- bash -lc \
    "export PATH=\"\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$PATH\"; $2"
}

# The 1-minute load average on MACHINE.
fleet_remote_load() { # machine
  fleet_remote "$1" 'if [ -r /proc/loadavg ]; then cut -d" " -f1 /proc/loadavg; else sysctl -n vm.loadavg | cut -d" " -f2; fi' 30
}
