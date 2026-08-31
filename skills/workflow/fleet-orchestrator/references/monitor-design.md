# Monitor design

Four monitors carry the shift. The settle monitor is the load-bearing one;
the others exist because it, too, can die.

## The acting monitor

One persistent watcher polls the agent inventory (`name|status|revision` per
lane) and diffs each poll against the last. It never exits on an event.

**It acts on routine events itself.** A non-verdict lane that settles gets a
sweep prompt sent straight to the coordinator, its name appended to the swept
ledger, and a line in the monitor log. The orchestrator is not woken and
learns about it at the next self-eval.

**It wakes the orchestrator only for judgment:**

| Wake | Trigger | Why it needs a person |
|------|---------|----------------------|
| verdict lane settled | lane name matches a verdict glob | a verdict must be read and ruled on |
| BLOCKED | same lane blocked on two consecutive polls | an approval dialog is waiting |
| VANISHED | lane disappeared while working or done, unswept | teardown without capture; output may be lost |
| SEED-MOVED | seed tip changed | something landed; push cadence and queue change |
| COORDINATOR-STALL | coordinator reports working with a frozen revision past the threshold | the loop is wedged, not busy |
| inventory unreadable | inventory call failed or returned nothing | the fleet may be gone |

Rules the design depends on:

- **Settle is a transition**, `working` → `done`/`idle`, never a status
  snapshot. Agents that poll an inbox report `working` forever and their
  revision counter climbs regardless of progress, so a snapshot both invents
  settles and hides them. Where a fleet has a stronger liveness signal than
  status (a work lock, a claim file), prefer it.
- **Blocked is debounced by one poll.** A single blocked reading is usually a
  lane between turns.
- **The swept ledger is the deduplication key.** It is append-only and
  trimmed, and a lane name in it never fires again — so dispatch fresh,
  role-and-ticket-derived lane names per cycle rather than reusing one name
  across attempts.
- **Baseline on the first poll.** Lanes that settled while no monitor was
  armed are handled immediately: routine ones swept, verdict ones woken. A
  monitor armed mid-shift must never start by forgetting the backlog.
- **Coordinator idleness is an event too.** Idle past the threshold with
  unswept settled lanes gets a direct pulse, rate-limited so a wedged
  coordinator is not spammed.
- **A heartbeat file every poll.** It is the only proof the monitor is alive,
  and self-eval reads it.

## Failure history behind these rules

- **Exit-and-restart watchers rot.** A watcher that exits when it fires must
  be relaunched by hand every time. Three forgotten relaunches in a single day
  produced blind windows of 78, 50, and 23 minutes, during which settled lanes
  sat unprocessed. A persistent watcher has no restart step to forget.
- **Every routine settle used to cost a main-loop round.** Waking a person to
  forward a message is waste; the acting design forwards it and loses nothing.
- **Never launch a monitor with `&`.** Shell jobs launched that way were
  orphaned twice: the job lived outside the harness's task list, then died
  with no heartbeat and no notice. Use the harness's persistent monitor facility, one
  launch, and check the heartbeat afterwards.
- **An operator nudge is an alarm.** If a person tells you an agent settled or
  a pipeline is red, the monitor failed. Fix the monitor before answering the
  nudge.

## The other three

- **CI watcher, one per push.** Armed with the full SHA immediately after the
  push, it writes a push-in-flight marker at the start, a heartbeat per poll,
  and clears the marker on a concluded result. It fails fast on the first
  failed conclusion instead of waiting for siblings. A push with no live
  watcher is forbidden. Watch for two traps: run lookups match on the full
  SHA, so a short SHA silently reports nothing; and a forge can drop a push
  event entirely, so if no run appears within a few polls the watcher
  triggers the configured workflow once, explicitly.
- **Self-eval at every wake.** See [self-eval.md](self-eval.md).
- **Cron watchdog, the watcher of the watchers.** A fixed-cadence external
  wake that re-invokes the orchestrator to run self-eval even when every
  monitor is dead. Two hygiene rules, both learned the hard way: the cron
  prompt is ONE line pointing at an instructions file
  ([watchdog-wake.md](watchdog-wake.md)) because a wall of inline text
  clutters the task list; and list-then-delete existing watchdog crons before
  creating one, because duplicates survive context compaction and stack up
  (three were once found running at once).

## Rearming

Monitors are session-scoped: they die with the session that launched them. A
successor's first act is to rearm all four and confirm the heartbeat files are
fresh before trusting any of them.
