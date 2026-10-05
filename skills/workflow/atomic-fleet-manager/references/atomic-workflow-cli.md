# Atomic workflow commands and goal-select inputs

Facts checked against Atomic's bundled docs
(`docs/workflows/operations.md` inside the installed Atomic package under
`~/.local/share/atomic/node_modules/`) and the goal-select definition
(`~/code/dotfiles/atomic/.atomic/agent/workflows/goal-select.ts`) on
2026-10-04. Re-read both when a command here fails; they are the authority.

## Launching from the TUI

```text
/workflow goal-select tracker=linear tracker_issue=TUS-150 model_policy_path=/abs/path/opus-astra.json
```

- Inputs are bare `key=value` tokens. A value is parsed as JSON when it can
  be, so `flag=true` is a boolean and `objective="two words"` is one string.
- The input picker opens only when no arguments were given or a required
  input is missing. With `tracker`, `tracker_issue` and `model_policy_path`
  supplied, the run dispatches straight away and every other input takes its
  default.
- A dispatched run prints a `DISPATCHED` card with the run's full UUID and
  then runs in the background of that Atomic session.

## goal-select inputs that matter here

| Input | Default | Use |
| --- | --- | --- |
| `tracker` | `none` | `linear` or `jira` fetches one issue read-only as the objective |
| `tracker_issue` | none | Issue key, URL or search words; a key is fetched directly |
| `model_policy_path` | shared default preset | Preset file read before every turn |
| `branch_checkout_dir` | `auto` | `auto` clones the invoking checkout's committed HEAD into `<seed>.goal-<issue>-<hash>`; a sibling clone's name continues in that clone |
| `objective` | none | With a tracker, added verbatim to the issue text |
| `acceptance_criteria` | the issue's own | Text here replaces them; leave it unset for follow-up runs |
| `create_pr` | `false` | Opt in explicitly; prompt text alone does not |
| `resolve_only` | `false` | Resolve models and preview the clone path, then stop; fetches no issue |

Presets live in `~/.config/atomic/goal-select-models/`, named
`<writer>-<reviewer>.json` (for example `opus-astra.json`, `glm-astra.json`).

## Reading a run

- The `BACKGROUND` panel line reads `goal-select · <mode> · <done>/<total> · <elapsed>`.
- `<mode>` is only a stage count: `single` while one stage has started,
  `chain` once a second has. A run that shows `single` for its first seconds
  and then `chain` is normal.
- With a tracker the first stages are the tracker check, the issue fetch and
  the Goal run, so a run reads `2/3` early on; the total grows as the Goal
  run adds stages (`3/6` was seen after 20 minutes).
- A paused run shows `1 paused` in the panel header and the pane goes `done`
  or `idle`. A harness may pause itself, for example when the issue says to
  start after another issue that has not landed.
- A `resolve_only` run finishes in under a second and reads
  `goal-select · complete`.
- Herdr's pane status for Atomic: `working` while the run is active,
  `blocked` when it needs an answer or approval, `idle` or `done` when
  nothing is running. A failed run can also end as `idle`; read the pane.

## Controlling a run from its tab

```text
/workflow status [run-id]
/workflow connect <run-id>            # graph viewer; chat with a stage
/workflow pause <run-id>
/workflow resume <run-id> [stage] msg
/workflow quit <run-id>               # pauses and keeps the run resumable
```

A run id is the full UUID or its first 8 hexadecimal characters.

## How steering travels (Intercom)

Atomic sessions and workflow stages message each other with the `intercom`
tool. It exists only inside Atomic, so an outside manager steers through
the Atomic chat in the issue's tab, which relays. Checked against the
bundled `docs/intercom.md` and `docs/intercom/reference.md` on 2026-10-04.

- **Address.** A stage is `workflow:<run id>/<stage>` (for example
  `workflow:<run id>/orchestrator-1`); `*` matches one segment and `**` any
  depth. The `sessionId` shown by `/workflow status` is not an address.
- **Joining.** The tab's chat must join the group `workflow:<run id>`
  before it can list, send to or ask that run's stages. It does this itself
  when asked to steer; name the run id so it joins the right one.
- **`send` or `ask`.** `send` returns once the message is transported; that
  receipt is not the model accepting it. `ask` waits for the stage's reply,
  up to 10 minutes, and needs a live stage. Ask the tab to use `ask` when
  you need an acknowledgement to relay.
- **Cost of a message.** A working stage treats a message as priority
  input: its current model call or cancellable tool is cancelled and the
  message is handled next. Side effects already completed are kept. Put all
  rulings in one message, and steer only when the run would otherwise go
  the wrong way.
- **Changing scope or acceptance.** Ask for one broadcast to
  `workflow:<run id>/**`. It reaches every live stage and is queued for
  every stage that starts later, so reviewers judge against the same
  ruling as the writer. A queued message reports `queued`, not delivered.
- **Paused runs.** A paused stage has no live target for `ask`.
  `/workflow resume <run id> <stage> <message>` forwards the message and
  resumes the run, but the word after the run id is read as the stage name,
  so a message without one fails with "Stage not found". Asking the tab's
  chat in plain language to resume and deliver the message is the reliable
  route.
- **No cross-harness messaging.** One run cannot message another run's
  stages, so harnesses do not learn about each other. A harness waiting on
  another issue stays paused until the outside manager resumes it with the
  news.

