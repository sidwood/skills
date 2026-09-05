---
name: fleet-coordinator
description: Use when coordinating a fleet of coding agents against task state or an optional ticket board — dispatching implementers or reviewers in a Herdr session, handling REVIEW-READY or APPROVE verdicts, bouncing, or landing branch clones — or when the user asks to run the fleet, work the board, or hand the ticket loop to an orchestrator.
---

# Fleet Coordinator

Operate fleet state as an event loop: every event maps to a table row, every
project binding lives in config, and every judgment call escalates to the
user. `fleet.json` is the source of truth; a board is an optional projection,
never a dependency. An unmatched situation stops for escalation — inventing
an action is the one unforgivable failure.

When an orchestrator supervises this loop (the `fleet-orchestrator` skill), it
is the escalation address instead of the user: it rules on the verdicts you
report, schedules the landing train, and owns pushes and monitors. Keep routine
settles in durable fleet state; the monitor sends reviewer events straight to
it, while you send escalations and execute a landing only in the slot it gives
you.

## Configuration contract

1. Locate the project's fleet config (by default
   `<seed>/temp/fleet/fleet.json`, or the path project instructions name). It
   owns every binding: seed repository path, Herdr
   session name, agent recipes, recipe enable switches and usage-pool state,
   reviewer pairing rules, verification gate commands, deployment context,
   land policy, bounce cap, and per-ticket stream state. To create or migrate
   one, read
   [references/fleet-config.md](references/fleet-config.md).
2. Run `fleet recipes sync` after creating or adopting the config, then run
   `fleet recipes check`. The packaged catalog owns recipe kinds, launch
   arguments, usage pools, and fallback order. Never hand-copy, trim, or
   rewrite that catalog; keep an unused recipe present with `enabled: false`.
   Dispatch is forbidden while `recipes check` reports `RECIPE-DRIFT`.
3. Never hardcode a binding the config owns. Read the seed tip from git
   (`git -C <seed> log --oneline -1`), never from a file.
4. Paste the config's `deploymentContext` block into every prompt you
   dispatch. Severity is judged against that context, never against an
   imagined production load.

## Workspace layout

- Reserve each workspace's first default tab and pane, labeled `1`, for the
  Operator. The initial pane returned by workspace creation is not an agent
  slot; never launch an agent there or repurpose it during recovery.
- Create a separate coordinator tab labeled `Coordinator` and set its pane
  label to `Coordinator` before starting the coordinator. These are display
  labels; keep the agent identifier unique across projects.
- Give every worker its own new tab. On adoption, verify the Operator's
  reservation and the coordinator labels; preserve Operator state when moving
  an existing agent out of the reserved pane. Record the reserved tab/pane IDs
  and coordinator location in the handover so successors preserve the layout.

## Workflow

1. Watch agent settles (monitor or poll). Pass a monitor event ID unchanged to
   `fleet capture --event-id --close`; the resulting `events[]` entry is
   durable processing proof. Event `closedAt`, event `teardownResolvedAt`, a
   `resolved-lost-output` event, or an exact correlated lane marked `closed` or
   `resolved` completes the monitor acknowledgement. A retry of the same ID
   succeeds without rereading the lane or recording the result twice, and
   resumes teardown when needed. The next dispatch is blocked until every
   earlier lane on the ticket is `closed` or `resolved`. On each new event,
   find its row
   below, run it, and report under
   [references/comms-contract.md](references/comms-contract.md) — plain
   five-year-old language, bullets, ⚠️ on every escalation and nothing else.
   No matching row: stop and escalate.
2. **Implementer settles** → CAPTURE (read the transcript before any
   teardown). Output contains REVIEW-READY with a tip SHA and gate table →
   record it, tear down, dispatch the assigned reviewer using the scoped
   review template. Conclusive hard-cap output → `fleet capture --event-id
   --close` records the capacity event, spends the selected recipe's pool, and
   dispatches the next configured fallback from the original requested
   recipe. Anything else → escalate with the captured tail.
3. **Reviewer settles** → when an orchestrator supervises the fleet, the
   monitor routes the event ID directly to it; if you observe the event by
   another path, forward that ID unchanged. Leave capture and the verdict
   ruling to the orchestrator, then apply the ruling it returns. In a
   standalone coordinator loop, CAPTURE and apply the same verdict table,
   escalating judgment to the user:
   - APPROVE: yes with no in-scope P0–P2 findings → land (step 5).
   - APPROVE: no with an in-scope P0–P2 and bounce count below the cap →
     bounce: a fix-only prompt naming the findings; the next review verifies
     the fix range only.
   - Bounce cap reached → escalate with a land, split, or kill
     recommendation. Never dispatch past the cap.
   - APPROVE: no where every P0–P2 carries a deferred tag → prompt violation;
     escalate, do not bounce.
   - No APPROVE line → escalate; never infer a verdict.
4. **Blocker lands** → dependents become ready; dispatch them while seats are
   free. An idle seat with ready work is a coordinator failure.
5. **Land** (only from the verdict table or explicit user instruction):
   rebase the clone onto the seed tip if the seed moved and rerun the
   affected checks; fast-forward the seed (`git merge --ff-only`); run the
   config's post-land checks; record the ticket done with verdicts and
   deferrals; unblock dependents. Keep the clone until origin has the
   commits, and never push — the user pushes.
6. Record every state change (phase, tips, verdicts, bounce counts, reviewer
   assignments) in the fleet config as it happens. When a board adapter is
   configured, update that projection in the same turn.

## Review discipline

- The first review of a slice is the only full-range pass (seed tip to branch
  tip). Every re-review verifies the named findings plus the fix-commit diff
  for regressions; a new finding on unchanged code joins the deferral list,
  never a bounce.
- Generate prompts from [references/prompt-templates.md](references/prompt-templates.md)
  with zero unresolved placeholders — refuse to dispatch a prompt containing
  `<`.
- Reviewer prompts carry a scope rule: a tag taxonomy, an explicit
  do-not-hunt list, and "APPROVE: no ONLY when a P0–P2 finding carries the
  in-scope tag".
- User rulings (overrules, accepted residuals) are pasted verbatim into every
  later prompt for that ticket; reviewers have no memory between cycles.
- Two findings of the same shape in consecutive cycles are a defect class:
  open a class ticket instead of bouncing instances.
- The acceptance bar is the ticket's done criteria under the deployment
  context, never "zero findings at maximum effort".

## Rules

- CAPTURE before teardown, always: read the agent transcript, record the
  verdict and findings, and only then close its tab. `fleet capture` falls
  back to the recorded pane after any agent-read failure. If the pane fallback
  also fails after a prior malformed capture, retry the exact event from its
  saved evidence with `--capture-file`. Use `resolve-event` only when output is
  irretrievable; never invent output.
- Treat monitor event IDs as opaque idempotency keys. Record the ID in the same
  atomic config write as the captured result; the monitor sweeps only after
  the exact event has `closedAt`, `teardownResolvedAt`, or kind
  `resolved-lost-output`, or its exact correlated lane is `closed` or
  `resolved`.
- Fresh tab and agent per dispatch; never reuse a settled pane.
- Resolve a dispatch recipe from its requested recipe plus that recipe's
  ordered, flat fallback list. Skip any recipe with `enabled: false` or a
  `spent` usage pool, record both requested and selected recipes on the lane,
  and raise an operator alert when none remains.
- Mark a usage pool `spent` only from conclusive captured evidence that its
  window or credits are exhausted. A reset offer, usage reminder,
  authentication problem, startup failure, timeout, or ambiguous message is
  not exhaustion and must not trigger a fallback. Always pass `--event-id
  --close` to capture: recognized hard-cap evidence performs the close, pool
  transition, and fresh fallback dispatch as one durable recovery. Never send
  capacity evidence through `resolve-event`; that command refuses it.
  Availability changes never replace an active lane.
- One writer per clone; dispatch refuses another role until every prior lane
  on that ticket is `closed` or `resolved`. Agents never touch the seed working
  copy.
- Report in plain five-year-old language, in bullets; the first line is the
  event and the action taken, precision goes in the linked files, and ⚠️ marks
  every escalation and nothing else. The operator scans your pane for exactly
  that marker: [references/comms-contract.md](references/comms-contract.md).

For Herdr commands, dialogs that swallow prompts, and recovery when an agent
deregisters, read [references/herdr-cli.md](references/herdr-cli.md).

## Scripts

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
| Fleet snapshot and next action | `fleet state` |
| Apply verdict table to newest capture | `fleet verdict <ticket> [--commit]` |
| Open tab, start agent, send prompt | `fleet dispatch <ticket> <impl\|review> --prompt-file <file>` |
| Fast-forward seed from approved clone | `fleet land <ticket>` |
| Gate commands for current diff | `fleet gate <ticket>` |

Run unit tests: `python3 -m unittest discover -s scripts/tests`.
