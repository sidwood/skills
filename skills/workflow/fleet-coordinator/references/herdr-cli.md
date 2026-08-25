# Herdr CLI mechanics

Herdr is generic; project bindings (session name, recipes, paths) come from
the fleet config. On syntax drift, inspect `herdr --help` and the relevant
command group — the binary wins over this document.

## Session and inventory

- If `HERDR_ENV=1`, keep inherited session and caller IDs. Otherwise run
  `herdr session list --json`, choose one, and pass `--session <name>` on
  every call; never default when unclear.
- `herdr api snapshot` inventories workspaces, tabs, panes, and agents.
- `herdr agent list` and `herdr tab list` return JSON; use only IDs returned
  by these calls.

## Dispatch

1. `herdr tab create --cwd <clone> --label "<ticket> <role>" --no-focus` —
   take the pane ID from `.result.root_pane.pane_id`.
2. `herdr agent start <name> --kind <kind> --pane <pane-id> --timeout 120000
   -- <recipe args>` — kind and args come from the fleet config's recipes.
   Agent names match `[a-z][a-z0-9_-]{0,31}` — no dots, so a ticket like
   T094.1 becomes `t094-1-impl`. Start agents directly; wrappers break agent
   detection.
3. `herdr agent prompt <name> "$(cat <prompt file>)" --wait --until working
   --timeout 20000`.

## Waiting and reading

- Settled means `idle`, `done`, or `blocked`; `unknown` is incomplete.
- `herdr agent wait <name> --timeout <ms>` blocks until settled. For
  long-running work, poll `herdr agent list` from a background monitor
  instead of blocking.
- `herdr agent read <name> --source recent-unwrapped --lines 200` returns the
  transcript tail. `--source visible` returns the current screen — use it to
  diagnose stalls and dialogs.
- Interact with a stuck TUI via `herdr agent send-keys`.

## Failure branches

- `agent_prompt_stalled` after a prompt: the TUI is showing a dialog or never
  received the text. Read `--source visible` and handle what is on screen,
  then re-send the prompt.
- Cursor agents (kind `cursor`): the first run in a directory shows a
  Workspace Trust dialog that swallows the first prompt. Accept it (send-keys
  `a`) or wait for it to clear, then re-send.
- Codex agents: a fresh TUI showing a usage-limit notice with an empty prompt
  means the account hit its limit and the prompt never ran. Spending a usage
  reset is the user's call — reroute to another reviewer family the pairing
  rules allow, or escalate.
- `agent_not_found` after a settle: the process exited and deregistered. Read
  the pane instead (`herdr pane read <pane-id> --lines 400`). If the pane is
  gone too, the output is lost — escalate. This is why CAPTURE always
  precedes tab close.

## Teardown

`herdr tab close <tab-id>` — only after a successful read and after the
verdict or REVIEW-READY is recorded. Close only resources you created.
