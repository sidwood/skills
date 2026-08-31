# Watchdog wake — standing instructions

The cron prompt is ONE line pointing at this file. Keep it that way: a wall of
inline text clutters the task list, and this file can be edited without
touching the schedule.

Suggested cron prompt:

```text
WATCHDOG WAKE: follow references/watchdog-wake.md in the fleet-orchestrator skill.
```

On every wake:

1. **Read the clock.** Run `date`. Never infer wall-clock time.
2. **Run `scripts/self-eval.sh`** and act on every finding in the same tick,
   never just note it:
   - `MONITOR-DOWN` → relaunch the named watcher now. The settle monitor goes
     through the harness's persistent monitor facility, never `&`. The CI
     watcher is armed with the full SHA from the push-in-flight marker.
   - `BOARD-STALE` → pulse the coordinator to regenerate the board.
   - `VELOCITY-STALL` → find the bottleneck and pulse the coordinator with it,
     named.
   - `QUEUE-DRIFT` / `ORPHANED` → order the coordinator to reconcile the fleet
     config against git.
   - `STALE-BLOCKERS` → order the dispatch immediately; push the top unblock
     levers, and escalate only the ones that need a person.
3. **Handle any wake the monitor surfaced that the loop has not.** Capture the
   lane to a suffixed file, read the verdict from the agent's own output, sweep
   the verdict and your ruling to the coordinator, then append the bare lane
   name to the swept ledger. Routine settles belong to the monitor, not to you.
4. **Check the push cadence.** All four gates green → push fast-forward only
   and arm the CI watcher in the same turn.
5. **Fill idle seats.** A coordinator idle with ready work gets a pulse; a
   ready ticket with no lane gets dispatched.
6. **Act, never note.** Hold quiet unless a person must decide something.

Before creating this cron, list the existing ones and delete stale duplicates.
Duplicates survive context compaction and stack up silently.
