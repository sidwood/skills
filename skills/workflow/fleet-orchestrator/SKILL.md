---
name: fleet-orchestrator
description: Use when supervising a coding-agent fleet from the main loop — arming settle and CI monitors, ruling on reviewer verdicts, running a landing train, pushing the seed and watching the deploy, or policing a fleet coordinator — or when the user asks to take fleet command, adopt a running fleet, run the orchestrator shift, or hand the shift to a successor.
---

# Fleet Orchestrator

Supervise a fleet you do not operate by hand. Monitors act on routine events,
the coordinator maintains `fleet.json` and any configured board projection,
and this role spends its turns on the four things only it can do: capture,
rule, land, push. Doing implementation work here without an explicit user
instruction is the failure mode — every minute in a diff is a minute the
fleet is unsupervised.

## Role split

| | Coordinator (`fleet-coordinator` skill) | Orchestrator (this skill) |
|---|---|---|
| Seat | a lane in the fleet, running an event loop | the main loop |
| Owns | dispatch, bounce, fleet state, optional board projection, commanded landing execution | monitors, reviewer capture and verdict rulings, landing authorization and train order, pushes, deploy watching |
| Escalates | unmatched events, bounce caps, rulings | operator-only decisions |
| Never | pushes, rules on scope | dispatches around the coordinator; implements without explicit user instruction |

Read the coordinator skill for the event table, prompt templates, and config
schema. This skill does not repeat them.

## Inputs

Bind `FLEET_SESSION` and `FLEET_SEED` before anything else. Runtime state and
the fleet config default to the seed's gitignored `temp/fleet/` directory;
overrides and optional bindings live in
[references/orchestrator-config.md](references/orchestrator-config.md).
Export them, or point `FLEET_ENV` at a file that sets them
(`scripts/fleet-orchestrator.env.example`).

## Workflow

1. **Bind the communication contract**, before your first report and for every
   turn after it: plain five-year-old language, bullets, answer first, detail
   linked from files, and ⚠️ only when work is stopped waiting on the operator.
   *Done when:* your first report is scannable bullets a five-year-old could
   follow, carrying ⚠️ only if the fleet is genuinely stopped on them. Full
   contract: [references/comms-contract.md](references/comms-contract.md).
2. **Adopt or verify the fleet.** Run `date`. Run `scripts/self-eval.sh` and
   read the computed queue, lane inventory, and drift lines. Reconcile every
   drift line with the coordinator before dispatching anything.
   *Done when:* self-eval prints no `QUEUE-DRIFT`, no `ORPHANED`, and the lane
   list matches the config's active streams.
3. **Arm four monitors.** The settle monitor (`scripts/fleet-monitor.sh`)
   through the harness's persistent facility, one launch, never `&`; its
   singleton lock rejects a second live copy. A CI watcher per push. Self-eval
   at every wake. A cron watchdog whose prompt is one line pointing at
   [references/watchdog-wake.md](references/watchdog-wake.md), created only
   after deleting stale duplicates.
   *Done when:* the heartbeat files are fresh and exactly one watchdog cron
   exists. Design and rationale:
   [references/monitor-design.md](references/monitor-design.md).
4. **Announce takeover to the coordinator** in one prompt: who you are, what
   you rule on, that reviewer settles route straight to you, and that it acts
   on your rulings and lands nothing without you.
   *Done when:* the coordinator acknowledges and its phase record matches
   step 2's reconciliation.
5. **Run the event loop on wake-class events only.** For each `WAKE verdict`,
   retain its `lane@state_change_seq` event ID, capture with that ID before any
   teardown, read the verdict from the agent's own output below the prompt
   echo, rule, and sweep the ruling to the coordinator. The monitor sees the
   durable capture plus event `closedAt`, event `teardownResolvedAt`, a
   `resolved-lost-output` event, or exact correlated-lane closure and moves the
   event from pending to swept.
   Handle every other wake by its row in
   [references/monitor-design.md](references/monitor-design.md). Routine
   settles are the monitor's job — never re-do them.
   *Done when:* every verdict wake ends with a capture or an auditable
   lost-output resolution, its ruling sent, and a ledger entry; every other
   wake's stated recovery is complete. Rules:
   [references/verdict-discipline.md](references/verdict-discipline.md).
6. **Land through one train, push on cadence.** Authorize one landing slot at
   a time; the coordinator performs the commanded fast-forward, and waiting
   clones stay idle. Run one full gate matrix at the batch tip. Push only with
   unpushed commits, green remote CI, green batch matrix, and no deploy in
   flight — fast-forward only, then arm the CI watcher in the same turn.
   *Done when:* the remote has the batch, a watcher is live on it, and the
   landed tips recorded are post-rebase seed SHAs. Law:
   [references/landing-and-push.md](references/landing-and-push.md).
7. **Police the fleet at every checkpoint.** Act on each self-eval finding in
   the same turn: relaunch dead watchers, refresh a stale optional projection,
   name the bottleneck behind a velocity stall, dispatch behind stale
   blockers, fill idle seats.
   *Done when:* no alarm line from the last run is still true.
   [references/self-eval.md](references/self-eval.md).
8. **Hand over or close the shift.** Write the handover from
   [references/shift-handover.md](references/shift-handover.md), have the
   successor rearm every monitor, and confirm their first checkpoint ran clean
   before you stop steering.
   *Done when:* one orchestrator is steering, with fresh heartbeats.

## Constraints

- Escalate to the operator only what only they can decide; mark it ⚠️, put the
  ask last with a recommendation, and stop that thread until they answer.
- Delegate all implementation, review, and optional board upkeep unless the
  user explicitly directs you to implement. Your normal work is capture,
  rulings, landing, pushes, and monitors.
- Capture before teardown, suffix re-reads, and read verdicts from the agent's
  own output. Never infer a verdict.
- A successful prompt submission is not a processing acknowledgement. Leave a
  settle pending until `fleet.json` contains its exact event ID and agent plus
  event `closedAt`, event `teardownResolvedAt`, kind `resolved-lost-output`, or
  an exact correlated lane marked `closed` or `resolved`.
- Compute the queue from the fleet config plus git every tick; trust the script
  over your memory of it.
- Push fast-forward only, one deploy in flight, and never a push without a live
  CI watcher.
- Treat an operator nudge about a settled lane or a red pipeline as a monitor
  failure: fix the monitor, then answer.
- Report in plain five-year-old language, in bullets: the event, the action
  taken, and what is now blocked on a person. Precision goes in the linked
  files. Reserve ⚠️ for work that is stopped on the operator, and expect most
  reports to carry none.

## Scripts

Every script reads its bindings from the environment or `FLEET_ENV`, prints
every missing binding at once, and refuses to run on a partial configuration.
No board is required; `FLEET_BOARD` only enables an optional stale-projection
check.

| Purpose | Command |
|---------|---------|
| Persistent settle monitor (acts on routine settles, wakes on judgment) | `scripts/fleet-monitor.sh` (`--once` to prove arming) |
| CI watcher for one pushed commit | `scripts/ci-watch.sh <pushed-sha>` |
| Deterministic checkpoint and queue reconciliation | `scripts/self-eval.sh` |
| Configuration template | `scripts/fleet-orchestrator.env.example` |
