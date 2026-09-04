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

Before each Herdr side effect, `fleet dispatch` advances the durable agent
record: `reserved` before tab creation, `tab-created` after it, `started`
after agent start, and `prompting` with `promptAttemptedAt` before prompt
submission. It writes `active` only after receipt is confirmed. A recorded lane
in any role slot blocks every next dispatch on that ticket until it is
`closed` or `resolved`. A captured lane therefore remains exclusive until its
tab is closed.

Automatic monitor recovery starts at `prompting`. A crash in `reserved`,
`tab-created`, or `started` requires explicit Herdr/config reconciliation; the
CLI refuses a same-role replacement rather than guessing which side effect
completed.

1. `herdr tab create --cwd <clone> --label "<ticket> <role>" --no-focus` —
   take the pane ID from `.result.root_pane.pane_id`.
2. If the selected recipe has `envPreStep`, send that trusted config command
   to the fresh pane and wait for its completion marker. GLM 5.3 uses this to
   load `$HOME/.claude-glm/lane.env`; a failure stops dispatch.
3. `herdr agent start <name> --kind <kind> --pane <pane-id> --timeout 120000
   -- <recipe args>` — kind and args come from the fleet config's recipes.
   Agent names match `[a-z][a-z0-9_-]{0,31}` — no dots. A stable ticket hash
   prevents normalized or truncated ticket IDs from colliding; the per-role
   dispatch counter gives every attempt a fresh suffix. Start agents directly;
   wrappers break agent detection.
4. `herdr agent prompt <name> "$(cat <prompt file>)" --wait --until working
   --timeout 60000`.

## Waiting and reading

- Settled means `idle`, `done`, or `blocked`; `unknown` is incomplete.
- `herdr agent wait <name> --timeout <ms>` blocks until settled. For
  long-running work, poll `herdr agent list` from a background monitor
  instead of blocking.
- `herdr agent read <name> --source recent-unwrapped --lines 200` returns the
  transcript tail. `--source visible` returns the current screen — use it to
  diagnose stalls and dialogs.
- The settle monitor treats `prompting` and `active` records as owned lanes.
  On startup, either state with no live lane becomes a durable
  `<lane>@missing` VANISHED event. It also rechecks settled lanes every poll,
  so a lane first seen idle before its record reached `active` is captured
  once the durable state catches up.
- Interact with a stuck TUI via `herdr agent send-keys`.

## Failure branches

- `agent_prompt_stalled` after a prompt: the TUI is showing a dialog or never
  received the text. Read `--source visible` and handle what is on screen,
  then re-send the prompt.
- Codex agents: when startup returns `agent_not_ready` at the numbered workspace
  trust chooser, dispatch accepts `1. Yes, continue` and waits for the existing
  process to register. If a first-run self-update finishes by requiring a Codex
  restart, dispatch replaces the disposable tab and retries that prompt once.
- Claude agents: when startup returns `agent_not_ready` with the trusted-folder
  safety chooser already focused on `Yes`, dispatch confirms it and waits for
  the existing process to register.
- Cursor agents (kind `cursor`): the first run in a directory shows a
  Workspace Trust dialog that swallows the first prompt. Accept it (send-keys
  `a`) or wait for it to clear, then re-send.
- A captured, explicit hard-limit result (usage window exhausted or no credits
  remain) is capacity evidence. `fleet capture <agent> --event-id <id> --close`
  preserves the transcript, closes and reconciles that exact lane, marks its
  configured usage pool `spent`, and immediately dispatches from the original
  requested recipe. The packaged recipe catalog therefore selects Cursor Grok
  XHigh after native Grok XHigh without a coordinator ruling.
- A reset offer or remaining-usage notice is informational, not a spent pool.
  Authentication, configuration, startup, timeout, and ambiguous failures are
  also not capacity evidence. Preserve their transcript and raise an operator
  alert instead of silently changing model. After the operator fixes the cause,
  retire the exact unusable settlement with `fleet resolve-event <agent>
  --event-id <id> --capture-file <saved-transcript> --reason <text>` before a
  fresh dispatch; this records invalid output, never a verdict or spent pool.
  `resolve-event` rejects recognized hard-cap evidence so it cannot turn a
  recoverable capacity transition into an ordinary hold.
- Any agent-read failure falls back to the recorded pane
  (`herdr pane read <pane-id> --lines 400`); `agent_not_found` after a process
  exits is the common case. If a prior failed capture saved the full output,
  retry the exact event with `fleet capture --capture-file <path>`. If the pane
  and saved evidence are both unavailable, the output is lost — escalate,
  then acknowledge the exact event with
  `fleet resolve-event <agent> --event-id <id> --reason <text>`.
  `resolve-event` is exceptional; it records lost output rather than a verdict.

## Teardown

`herdr tab close <tab-id>` — only after the transcript tail is saved,
successfully parsed, and the verdict or REVIEW-READY is recorded. Close only
resources you created. A repeated `fleet capture --event-id <id> --close`
does not reread or duplicate the capture; it finishes teardown unless the
config already says closed. Every next dispatch on the ticket remains blocked
until this completes. An already-missing tab is successful recovery from a
close-save crash. If an already-captured event has lost or irrecoverably
ambiguous tab identity, escalate and use `fleet resolve-event` with its exact
ID and a reason; this records teardown resolution without claiming a close.
