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
   - `CHECKOUT-DRIFT` → stop the affected next dispatch; repair BC
     tooling/provenance/layout yourself without moving or deleting active work.
   - `BOARD-STALE` → when an optional board projection is configured, rerun
     any config-mutating `fleet` command to regenerate it.
   - `VELOCITY-STALL` → find the bottleneck and dispatch behind it, named.
   - `QUEUE-DRIFT` / `ORPHANED` → reconcile the fleet config against git
     yourself.
   - `STALE-BLOCKERS` → dispatch immediately; push the top unblock
     levers, and escalate only the ones that need a person.
3. **Finish overdue handoffs.** A captured implementation/fix is not handed
   off until the assigned reviewer is verified working and the board is
   current. Inspect the actual blocker, recover it directly, and verify the
   next lane; a phase change or accepted prompt alone is insufficient.
4. **Handle any wake the monitor surfaced that the loop has not.** For a
   `WAKE verdict`, capture with the event ID, read the agent's verdict, and
   rule; bounce, land, or escalate from the ruling yourself. For every other
   wake, follow its row in [monitor-design.md](monitor-design.md);
   irretrievably lost output uses the auditable `resolve-event` path there.
   Routine settles arrive batched as `SETTLED` lines; work each per the event
   table in SKILL.md.
5. **Check the push cadence.** All four gates green → push fast-forward only
   and arm the CI watcher in the same turn.
6. **Fill idle seats.** A ready ticket with no lane gets dispatched; idle
   capacity with ready work is your failure, not the lane's.
7. **Act, never note.** Hold quiet unless a person must decide something.

On adoption, verify the independent local watchdog and its destination; see
[local-watchdog.md](local-watchdog.md). Keep superseded AI heartbeats paused.
Do not reintroduce scheduled model polling to check whether local polling is
healthy: the local watchdog performs that check without a model.
