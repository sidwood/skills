# Watchdog wake — standing instructions

The local watchdog queues this task only when action is needed. Its message
names incident keys and the local evidence; read that evidence before acting.
Healthy polling runs outside the model and must not generate AI turns.

On every wake:

1. **Read the clock.** Run `date`. Never infer wall-clock time.
2. **Run `scripts/self-eval.sh`** and act on every finding in the same tick,
   never just note it:
   - `MONITOR-DOWN` → relaunch the named watcher now. The settle monitor goes
     through the harness's persistent monitor facility, never `&`. The CI
     watcher is armed with the full SHA from the push-in-flight marker.
   - `CHECKOUT-DRIFT` → stop the affected next dispatch; have the coordinator
     repair BC tooling/provenance/layout without moving or deleting active work.
   - `BOARD-STALE` → when an optional board projection is configured, pulse
     the coordinator to run its adapter and regenerate it.
   - `VELOCITY-STALL` → find the bottleneck and pulse the coordinator with it,
     named.
   - `QUEUE-DRIFT` / `ORPHANED` → order the coordinator to reconcile the fleet
     config against git.
   - `STALE-BLOCKERS` → order the dispatch immediately; push the top unblock
     levers, and escalate only the ones that need a person.
3. **Finish overdue handoffs.** A captured implementation/fix is not handed
   off until the assigned reviewer is verified working and the board is
   current. Inspect the actual blocker, recover through the coordinator, and
   verify the next lane; a phase change or accepted prompt alone is insufficient.
4. **Handle any wake the monitor surfaced that the loop has not.** For a
   `WAKE verdict`, capture with the event ID, read the agent's verdict, and
   send the ruling to the coordinator. For every other wake, follow its row in
   [monitor-design.md](monitor-design.md); irretrievably lost output uses the
   auditable `resolve-event` path there. Routine settles belong to the monitor,
   not to you.
5. **Check the push cadence.** All four gates green → push fast-forward only
   and arm the CI watcher in the same turn.
6. **Fill idle seats.** A coordinator idle with ready work gets a pulse; a
   ready ticket with no lane gets dispatched.
7. **Act, never note.** Hold quiet unless a person must decide something.

On adoption, verify the independent local watchdog and its destination; see
[local-watchdog.md](local-watchdog.md). Keep superseded AI heartbeats paused.
Do not reintroduce scheduled model polling to check whether local polling is
healthy: the local watchdog performs that check without a model.
