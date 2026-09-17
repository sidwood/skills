---
name: fleet-orchestrator
description: Use when running or supervising a coding-agent fleet from the main loop — dispatching implementers and reviewers in a Herdr workspace, handling SETTLED events and reviewer verdicts, bouncing, landing, arming settle and CI monitors, running the landing train, pushing the seed, or watching the deploy — or when the user asks to run the fleet, work the board, take fleet command, adopt a running fleet, or hand the shift to a successor.
---

# Fleet Orchestrator

One operator runs the fleet: you. Every agent settlement reaches your desk as
a `SETTLED` or `WAKE` line from the persistent monitor, and this skill is the
event table that maps each to an action. `fleet.json` is the source of truth;
a board is an optional projection, never a dependency. An unmatched situation
stops for operator escalation — inventing an action is the one unforgivable
failure. Doing ticket implementation work without an explicit operator
instruction is the other one; your work is the loop, not the diffs.

## Inputs

Bind `FLEET_WORKSPACE` and `FLEET_SEED` before anything else. Use one Herdr
session for all projects and one workspace per project. `FLEET_SESSION` is
optional: when absent, every command uses Herdr's default session. Runtime
state and the fleet config default to the seed's gitignored `temp/fleet/`
directory; overrides and optional bindings live in
[references/orchestrator-config.md](references/orchestrator-config.md).
Export them, or point `FLEET_ENV` at a file that sets them
(`scripts/fleet-orchestrator.env.example`).

The fleet config (`<seed>/temp/fleet/fleet.json` by default) owns every
binding: seed repository path, Herdr workspace ID, optional shared session
name, agent recipes, recipe enable switches and usage-pool state, reviewer
pairing rules, verification gate commands, deployment context, land policy,
bounce cap, and per-ticket stream state. Give each project one workspace
inside the shared Herdr session; never create a project-named session for
isolation. To create or migrate a config, read
[references/fleet-config.md](references/fleet-config.md).

Run `fleet recipes sync` after creating or adopting the config, then
`fleet recipes check`. The packaged catalog
([assets/recipe-catalog.json](assets/recipe-catalog.json)) owns recipe kinds,
launch arguments, usage pools, and fallback order. Never hand-copy, trim, or
rewrite that catalog; keep an unused recipe present with `enabled: false`.
Dispatch is forbidden while `recipes check` reports `RECIPE-DRIFT`.

Never hardcode a binding the config owns. Read the seed tip from git
(`git -C <seed> log --oneline -1`), never from a file. Paste the config's
`deploymentContext` block into every prompt you dispatch; severity is judged
against that context, never against an imagined production load.

## Branch checkouts

Every fleet checkout uses Sid's dotfiles BC tools: `git bc-add` to create,
`git bc-list` to inspect, `git bc-rm` / `git bc-prune` to remove eligible
clones. Read each tool's `-h` before use. Never substitute `git clone`,
`git worktree`, or a repository copy when the tool is missing or fails. You
create checkouts with `fleet checkout TICKET`; workers never create their
own. New checkouts live beside the seed, never inside `temp/fleet`, and
dispatch must verify the clone's branch, Git directory, and `bc.source`
chain before any agent state or Herdr tab is created. A path in JSON is not
proof that a checkout follows this rule. For creation, existing fleets, and
cleanup, read [references/branch-checkouts.md](references/branch-checkouts.md).

`CHECKOUT-DRIFT` blocks the next dispatch on the affected ticket. Repair the
checkout through BC tools or obtain an explicit continuation ruling for an
existing clone; do not invent `bc.source`, move an active checkout, suppress
the check, or replace BC with raw Git/copy commands. Only the operator can
approve a legacy layout continuation; it never authorizes a new clone.

## Workspace layout

- Set the workspace label to the basename of its cwd, such as
  `brain-cylinder`, `skills`, or `dotfiles`. Verify this on creation and
  adoption; rename the existing workspace rather than replacing it.
- Reserve each workspace's first default tab and pane, labeled `1`, for the
  Operator. The initial pane returned by workspace creation is not an agent
  slot; never launch an agent there or repurpose it during recovery.
- Give every worker its own new tab. On adoption, verify the Operator's
  reservation; preserve Operator state when moving an existing agent out of
  the reserved pane. Record the reserved tab/pane IDs in the handover so
  successors preserve the layout.

## Workflow

1. **Bind the communication contract**, before your first report and for
   every turn after it: plain five-year-old language, bullets, answer first,
   detail linked from files, and ⚠️ only when work is stopped waiting on the
   operator.
   *Done when:* your first report is scannable bullets a five-year-old could
   follow, carrying ⚠️ only if the fleet is genuinely stopped on them. Full
   contract: [references/comms-contract.md](references/comms-contract.md).
2. **Adopt or verify the fleet.** Run `date`. Run `scripts/self-eval.sh` and
   read the configured workspace's computed queue, lane inventory,
   recipe-catalog status, and drift lines. `RECIPE-DRIFT` means you must run
   `fleet recipes sync` before any dispatch. Reconcile every drift line;
   agents in other workspaces are other projects, not fleet orphans.
   *Done when:* self-eval prints no `WORKSPACE-DRIFT`, no `RECIPE-DRIFT`, no
   `QUEUE-DRIFT`, no `ORPHANED`, and the lane list matches the config's
   active streams.
3. **Arm local monitors.** The settle monitor (`scripts/fleet-monitor.sh`)
   runs through the harness's persistent facility, one launch, never `&`;
   its singleton lock rejects a second live copy. Use a CI watcher per
   authorized push and self-eval on actionable wakes. Run the independent
   local watchdog under the OS scheduler; healthy checks must make zero
   model calls. It queues a message to you only for an actionable incident.
   Setup and verification:
   [references/local-watchdog.md](references/local-watchdog.md).
   *Done when:* the monitor heartbeat is fresh, one local watchdog is armed,
   healthy probes make no AI calls, and issue delivery has been tested.
   Pause any existing AI heartbeat after local coverage is verified; do not
   create periodic model checks without explicit operator approval.
4. **Run the event loop** on every `SETTLED` and `WAKE` line the monitor
   prints. The line carries event identity only; the rows below are the
   instruction. Pass a monitor event ID unchanged to
   `fleet capture --event-id --close`; the resulting `events[]` entry is
   durable processing proof. A settle is complete only when `fleet.json`
   contains its exact event ID and agent plus event `closedAt`, event
   `teardownResolvedAt`, a `resolved-lost-output` event, or an exact
   correlated lane marked `closed` or `resolved`. A retry of the same ID
   succeeds without rereading the lane or recording the result twice, and
   resumes teardown when needed. The next dispatch is blocked until every
   earlier lane on the ticket is `closed` or `resolved`. No matching row:
   stop and escalate. Other wake classes follow their rows in
   [references/monitor-design.md](references/monitor-design.md); rules in
   [references/verdict-discipline.md](references/verdict-discipline.md).
   - **Implementer settles** (`SETTLED <id=state,...>`) → CAPTURE (read the
     transcript before any teardown). Output contains REVIEW-READY with a
     tip SHA and gate table → record it, tear down, dispatch the assigned
     reviewer using the scoped review template. Conclusive hard-cap output →
     `fleet capture --event-id --close` records the capacity event, spends
     the selected recipe's pool, and dispatches the next configured fallback
     from the original requested recipe. Anything else → escalate with the
     captured tail.
   - **Reviewer settles** (`WAKE verdict <id...>`) → retain its
     `lane@state_change_seq` event ID, capture with that ID before any
     teardown, read the verdict from the agent's own output below the prompt
     echo, rule, and apply the ruling yourself:
     - APPROVE: yes with no in-scope P0–P2 findings → land (step 6).
     - APPROVE: no with an in-scope P0–P2 and bounce count below the cap →
       bounce: a fix-only prompt naming the findings; the next review
       verifies the fix range only.
     - Bounce cap reached → escalate with a land, split, or kill
       recommendation. Never dispatch past the cap.
     - APPROVE: no where every P0–P2 carries a deferred tag → prompt
       violation; escalate, do not bounce.
     - No APPROVE line → escalate; never infer a verdict.
   - **Blocker lands** → dependents become ready; dispatch them while seats
     are free. An idle seat with ready work is your failure.
   - **Land** (only from the verdict table or explicit operator
     instruction): rebase the clone onto the seed tip if the seed moved and
     rerun the affected checks; fast-forward the seed with
     `fleet land <ticket>`; run the config's post-land checks; record the
     ticket done with verdicts and deferrals; unblock dependents. Keep the
     clone until origin has the commits.
   - **Record every state change** (phase, tips, verdicts, bounce counts,
     reviewer assignments) in the fleet config as it happens. When a board
     adapter is configured, the next config-mutating `fleet` command reruns
     its `boardRefreshCommand`; verify the projection in the same turn.
   *Done when:* every settle ends with a capture or an auditable lost-output
   resolution and every wake's stated recovery is complete.
5. **Land through one train, push on cadence.** Authorize one landing slot
   at a time; waiting clones stay idle. Run one full gate matrix at the
   batch tip. Push only with unpushed commits, green remote CI, green batch
   matrix, and no deploy in flight — fast-forward only, then arm the CI
   watcher in the same turn.
   *Done when:* the remote has the batch, a watcher is live on it, and the
   landed tips recorded are post-rebase seed SHAs. Law:
   [references/landing-and-push.md](references/landing-and-push.md).
6. **Police the fleet at every checkpoint.** Act on each self-eval finding in
   the same turn: relaunch dead watchers, refresh a stale optional
   projection, name the bottleneck behind a velocity stall and dispatch
   behind stale blockers, fill idle seats. A `CAPACITY-STALL` or
   `CAPACITY-RECOVERY-FAILED` means the automatic recovery needs a retry of
   the exact capture event; run it yourself, escalating only when the
   configured route is truly exhausted.
   *Done when:* no alarm line from the last run is still true.
   [references/self-eval.md](references/self-eval.md).
7. **Hand over or close the shift.** Write the handover from
   [references/shift-handover.md](references/shift-handover.md), have the
   successor rearm every monitor, and confirm their first checkpoint ran
   clean before you stop steering.
   *Done when:* one orchestrator is steering, with fresh heartbeats.

## Review discipline

- The first review of a slice is the only full-range pass (seed tip to
  branch tip). Every re-review verifies the named findings plus the
  fix-commit diff for regressions; a new finding on unchanged code joins the
  deferral list, never a bounce.
- Generate prompts from
  [references/prompt-templates.md](references/prompt-templates.md) with zero
  unresolved placeholders — refuse to dispatch a prompt containing `<`.
- Reviewer prompts carry a scope rule: a tag taxonomy, an explicit
  do-not-hunt list, and "APPROVE: no ONLY when a P0–P2 finding carries the
  in-scope tag".
- Operator rulings (overrules, accepted residuals) are pasted verbatim into
  every later prompt for that ticket; reviewers have no memory between
  cycles.
- Two findings of the same shape in consecutive cycles are a defect class:
  open a class ticket instead of bouncing instances.
- The acceptance bar is the ticket's done criteria under the deployment
  context, never "zero findings at maximum effort".

## Constraints

- Escalate to the operator only what only they can decide; mark it ⚠️, put
  the ask last with a recommendation, and stop that thread until they
  answer.
- Your work is capture, dispatch, rulings, bounce, landing, pushes, and
  monitors. Never write ticket code yourself unless the operator explicitly
  directs you to implement.
- CAPTURE before teardown, always: read the agent transcript, record the
  verdict and findings, and only then close its tab. `fleet capture` falls
  back to the recorded pane after any agent-read failure. If the pane
  fallback also fails after a prior malformed capture, retry the exact event
  from its saved evidence with `--capture-file`. Use `resolve-event` only
  when output is irretrievable; never invent output.
- A successful prompt submission is not a processing acknowledgement. Leave
  a settle pending until `fleet.json` contains its exact event ID and agent
  plus event `closedAt`, event `teardownResolvedAt`, kind
  `resolved-lost-output`, or an exact correlated lane marked `closed` or
  `resolved`.
- Treat monitor event IDs as opaque idempotency keys. Record the ID in the
  same atomic config write as the captured result; the monitor sweeps only
  after the exact event has `closedAt`, `teardownResolvedAt`, or kind
  `resolved-lost-output`, or its exact correlated lane is `closed` or
  `resolved`.
- Compute the queue from the fleet config plus git every actionable wake;
  trust the script over your memory of it.
- Fresh tab and workspace-namespaced agent per dispatch; create every tab in
  the configured project workspace and never reuse a settled pane.
- Never hand-wave a custom lane from `agent start` to prompt submission.
  After every non-ticket/custom start, run `scripts/herdr_agent_ready.py`
  with the exact agent, pane, and recipe kind; it clears known one-time
  trust dialogs and proves the TUI is prompt-ready. Submit the real brief
  immediately after `READY`, then verify receipt. A trust dialog is
  expected startup work, not an operator blocker.
- Resolve a dispatch recipe from its requested recipe plus that recipe's
  ordered, flat fallback list. Skip any recipe with `enabled: false` or a
  `spent` usage pool, record both requested and selected recipes on the
  lane, and raise an operator alert when none remains.
- Mark a usage pool `spent` only from conclusive captured evidence that its
  window or credits are exhausted. A reset offer, usage reminder,
  authentication problem, startup failure, timeout, or ambiguous message is
  not exhaustion and must not trigger a fallback. Always pass `--event-id
  --close` to capture: recognized hard-cap evidence performs the close, pool
  transition, and fresh fallback dispatch as one durable recovery. Never
  send capacity evidence through `resolve-event`; that command refuses it.
  Availability changes never replace an active lane.
- One writer per clone; dispatch refuses another role until every prior lane
  on that ticket is `closed` or `resolved`. Agents never touch the seed
  working copy.
- Push fast-forward only, one deploy in flight, and never a push without a
  live CI watcher.
- Treat an operator nudge about a settled lane or a red pipeline as a monitor
  failure: fix the monitor, then answer.
- Capture before teardown, suffix re-reads, and read verdicts from the
  agent's own output. Never infer a verdict.
- Report in plain five-year-old language, in bullets: the event, the action
  taken, and what is now blocked on a person. Precision goes in the linked
  files. Reserve ⚠️ for work that is stopped on the operator, and expect
  most reports to carry none.

For Herdr commands, dialogs that swallow prompts, and recovery when an agent
deregisters, read [references/herdr-cli.md](references/herdr-cli.md).

## Scripts

Every script reads its bindings from the environment or `FLEET_ENV`, prints
every missing binding at once, and refuses to run on a partial
configuration. No board is required; `FLEET_BOARD` only enables an optional
stale-projection check.

| Purpose | Command |
|---------|---------|
| Local watchdog (zero AI calls on healthy checks) | `scripts/fleet-watchdog.py --help` |
| Persistent settle monitor (all events reach you on stdout) | `scripts/fleet-monitor.sh` (`--once` to prove arming) |
| CI watcher for one pushed commit | `scripts/ci-watch.sh <pushed-sha>` |
| Deterministic checkpoint and queue reconciliation | `scripts/self-eval.sh` |
| Configuration template | `scripts/fleet-orchestrator.env.example` |

Executable helpers live in `scripts/fleet.py`. Config precedence is
`--config`, `FLEET_CONFIG`, `$FLEET_STATE_DIR/fleet.json`, then
`$FLEET_SEED/temp/fleet/fleet.json`. Every mutating subcommand accepts
`--dry-run`.

| Workflow step | Command |
|---------------|---------|
| Render implementer / review / bounce prompt | `fleet prompt <ticket> <implementer\|review\|bounce> --out <file>` |
| Capture agent output (before tab close) | `fleet capture <agent-name> [--event-id <lane@seq>] [--capture-file <saved-transcript>] [--close]` |
| Acknowledge irretrievably lost output or teardown | `fleet resolve-event <agent-name> --event-id <lane@seq> --reason <text>` |
| Install or verify all launch recipes and fallback routes | `fleet recipes sync`; `fleet recipes check` |
| Create the ticket checkout with BC tools | `fleet checkout <ticket>` |
| Verify checkout layout and BC provenance | `fleet checkouts check` |
| Fleet snapshot and next action | `fleet state` |
| Apply verdict table to newest capture | `fleet verdict <ticket> [--commit]` |
| Open tab, start agent, send prompt | `fleet dispatch <ticket> <impl\|review> --prompt-file <file>` |
| Fast-forward seed from approved clone | `fleet land <ticket>` |
| Gate commands for current diff | `fleet gate <ticket>` |

Run unit tests: `python3 -m unittest discover -s scripts/tests`.
