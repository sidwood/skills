# Monitor design

<!-- cspell:ignore unacked -->

Four monitors carry the shift. The settle monitor is the load-bearing one;
the others exist because it, too, can die.

## The acting monitor

One persistent watcher polls the agent inventory every ten seconds by default
(`name|status|state_change_seq|spinner` per lane) and diffs each poll against
the last. It never exits on an event. A healthy poll writes only local state
and emits exactly zero bytes on stdout and stderr, hence no model-visible
tokens when the harness reads process output.

**It persists every settle before notification.** Each settle enters the
pending queue under its immutable `lane@state_change_seq` ID. Routine events
from one poll are batched into one terse coordinator prompt; verdict events
produce one terse orchestrator wake. Transport success proves delivery only:
either kind remains pending until `fleet.json` records an event with the same
`eventId` and `agent`, then records a close, lost-output resolution, or
auditable teardown resolution. Only then does the monitor append the ID to the
swept ledger. A capture that remains
open past the configurable 30-second teardown grace emits a terse teardown
wake carrying its exact event ID and stays pending until close; the
already-captured event is not redelivered to the coordinator. Lost teardown
wakes retry on the same acknowledgement backoff. Missing, malformed, or
future-dated capture timestamps bypass the grace.

Before each notification side effect, the monitor records its epoch and
increments its attempt count. A crash after Herdr accepts a prompt therefore
cannot cause an immediate duplicate turn; a crash just before submission only
delays the durable retry. `herdr agent prompt` errors can be advisory after the
prompt was accepted, so failed and accepted-but-unacknowledged attempts stay
pending. Retry delay grows with the attempt count:
`FLEET_ACK_TIMEOUT_SECONDS × 1, 2, 4, 8`, capped at `8×`. An overdue
coordinator acknowledgement emits one compact wake even while the coordinator
is working, but the actual retry waits until that lane is not working to avoid
queueing duplicate turns. Repeated identical failures are silent until
recovery resets their deduplication key. This is at-least-once delivery, so
capture by event ID must be idempotent.

**It wakes the orchestrator only for action:**

| Wake | Trigger | Recovery |
|------|---------|----------|
| `WAKE verdict <event-id>…` | config records the lane's role as `review` | capture and rule under [verdict-discipline.md](verdict-discipline.md) |
| `WAKE blocked <lane>` | same lane blocked on two consecutive polls | read the visible pane and clear or escalate the dialog |
| `WAKE vanished <event-id>…` | owned lane disappeared while working, done, or idle, unswept | try agent then pane capture; use auditable resolution below only if both fail |
| `WAKE seed <old> <new>` | seed tip changed | run self-eval and re-evaluate the landing and push train |
| `WAKE coordinator missing` | readable inventory contains worker lanes but no coordinator | inspect or restart the coordinator lane before relying on routine delivery |
| `WAKE coordinator-stall <seconds>` | coordinator sequence froze with no spinner for the stall window | inspect its visible pane and recover or restart its loop |
| `WAKE inventory` | inventory call failed or returned no lanes | restore a readable session inventory, then let startup reconciliation run |
| `WAKE delivery <event-id>…` | coordinator prompt command failed | inspect the target and pending record; preserve it for timed retry |
| `WAKE unacked <event-id>…` | coordinator acknowledgement is overdue | inspect the target and config; preserve it for backoff retry |
| `WAKE teardown <event-id>…` | a capture exceeded its teardown grace without a durable close | retry `fleet capture <lane> --event-id <id> --close`; a legacy record receives the stable `<lane>@captured` ID; record an auditable resolution for an unrecoverable orphan |
| `WAKE state <target>` | config, heartbeat, pending queue, or ledger cannot be read or written | repair the named state, then let the next poll reconcile it |

Rules the design depends on:

- **Settle identity comes from the transition sequence.** Detect entry into
  `done`/`idle`, including a lane first observed already settled and
  `blocked` → `done`. Reconcile the durable pending queue every poll, rather
  than relying on two adjacent samples for retry. Where a fleet has a stronger
  liveness signal than status, prefer it.
- **Durable dispatch state exposes startup gaps.** `fleet dispatch` persists
  `prompting` before prompt submission and `active` after confirmed receipt.
  The monitor owns both states. Once inventory is readable, its startup pass
  turns a missing owned lane into `<lane>@missing`; it also rechecks every
  settled snapshot, so a lane first seen idle while its record is still being
  advanced is not forgotten.
- **Role comes from the config.** A recorded `review` role routes to the
  orchestrator and `impl` routes to the coordinator. Lane-name globs are only
  a compatibility fallback for older records with no role.
- **Blocked is debounced by one poll.** A single blocked reading is usually a
  lane between turns.
- **A stall needs two dead signals, and the revision field is not one of
  them.** A revision counter that looks like progress is a trap: some agent
  kinds sit frozen at their first value for an entire session while working
  perfectly, so "revision unchanged" fires a false stall on them and hides a
  real one on the seats whose counter climbs by itself. Use instead:
  - the **transition sequence** (`state_change_seq`), which increments only on
    a genuine state change, and
  - the **spinner glyph** in the pane's terminal title (braille,
    U+2800–U+28FF), which proves the pane is rendering at the sampled instant.

  Declare a stall only when the lane reports working, the sequence has been
  frozen for the whole stall window, **and** not one poll in that window saw a
  spinner. Either signal alone is normal: a long turn legitimately freezes the
  sequence, and the spinner blinks between samples. A window that ends with
  sightings is a healthy long turn — log it and re-arm silently. Re-arm after a
  wake too, so the next window is judged on its own evidence rather than
  re-firing every poll.
- **The swept ledger contains immutable event IDs.** It is append-only and is
  written only after durable acknowledgement. Dispatch also uses a fresh,
  numbered lane name per cycle, so transcripts and config events cannot be
  confused across a bounce or re-review.
- **Baseline on the first poll.** Lanes that settled while no monitor was
  armed are handled immediately: routine ones queued, verdict ones woken. A
  monitor armed mid-shift must never start by forgetting the backlog.
- **A heartbeat follows a readable inventory.** It is the proof that the
  monitor is alive and can still see the fleet; self-eval treats a 30-second
  stale heartbeat as down by default.
- **Seed visibility is independent.** A failed seed-tip read emits one
  `WAKE state seed`, preserves the last readable tip, and rearms silently on
  recovery; a real tip change during the blind window still produces one seed
  wake.
- **Runtime state is local and ignored.** Config, pending/swept ledgers,
  fault deduplication, heartbeats, logs, and captures default to
  `<seed>/temp/fleet/`. Do not run `git clean -fdx` while a fleet is live.
- **One watcher owns the ledgers.** A process-lifetime POSIX record lock admits
  one monitor. The kernel releases it on normal exit, `SIGKILL`, or host crash;
  stale PID text in the persistent lock file is diagnostic only and never
  blocks restart. Never delete or replace `FLEET_MONITOR_LOCK_FILE` while a
  monitor may be live, because a new inode would admit a second owner.

### Vanished-event recovery

Reconcile pending acknowledgements before disappearance detection, so a lane
captured and closed between polls is not reported as vanished. If a lane
disappears while its settle is pending, keep the same immutable event ID,
change its state and target to `vanished`, and make its wake immediately due.

## Pending-event record and exceptional resolution

Each tab-separated pending row stores event ID, lane, observed state,
last-send epoch, attempt count, and delivery target. Self-eval shows its age,
attempts, and target without consuming model tokens on a healthy monitor poll.
If `fleet.json` is unreadable, the monitor emits one state wake and suppresses
delivery until it can check for an existing acknowledgement again.
If the pending queue is unreadable, malformed, or contains a duplicate event
ID or lane, the monitor emits one `WAKE state pending` and fails closed before
adding or delivering anything. Recovery rearms that alarm for a later outage.

If both agent and pane reads fail, run
`fleet resolve-event <agent> --event-id <lane@seq> --reason <text>`. This
exceptional command writes an auditable `resolved-lost-output` event with the
exact ID and agent; the monitor then acknowledges it and moves it from pending
to swept normally. It is not a substitute for a malformed verdict or a missed
read attempt. It puts the stream on hold and preserves its prior phase;
re-dispatching the lost role restores the appropriate phase. Never append a
bare lane name to the ledger. When the capture exists but its close cannot be
recovered, the same command instead records an auditable
`teardownResolvedAt` and reason on the exact event. Legacy bare rows are
retained as inert history, but never suppress delivery: only an exact event in
`fleet.json` is trusted.

## Failure history behind these rules

- **Exit-and-restart watchers rot.** A watcher that exits when it fires must
  be relaunched by hand every time. Three forgotten relaunches in a single day
  produced blind windows of 78, 50, and 23 minutes, during which settled lanes
  sat unprocessed. A persistent watcher has no restart step to forget.
- **Every routine settle used to cost a main-loop round.** Waking a person to
  forward a message is waste; the acting design forwards it and loses nothing.
- **Transport success used to masquerade as processing success.** The monitor
  discarded `herdr agent prompt` failures and marked lanes swept anyway. A
  crash, rejection, or swallowed prompt could therefore lose a settle
  forever. Durable pending events plus config acknowledgements close that
  hole.
- **Never launch a monitor with `&`.** Shell jobs launched that way were
  orphaned twice: the job lived outside the harness's task list, then died
  with no heartbeat and no notice. Use the harness's persistent monitor
  facility, one launch, and check the heartbeat afterwards.
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
