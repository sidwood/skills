# Self-evaluation checkpoint

`scripts/self-eval.sh` is the deterministic checkpoint. Run it at **every**
wake — monitor event, watchdog tick, shift start, or before any push — and
answer three questions against its output:

1. Is the fleet moving correctly?
2. What can be improved?
3. What efficiency is available?

Every finding becomes an action in the same turn. A finding recorded as a note
is a finding you will meet again, larger.

## What it reports, and what each alarm demands

| Section | Alarm | Action, same turn |
|---------|-------|-------------------|
| deadline | — | re-plan the remaining work if it does not fit |
| lanes | `settled-unswept` | recover or rearm the settle monitor; `impl` routes to the coordinator and `review` routes to the orchestrator |
| lanes | `blocked` | clear the waiting dialog |
| lanes | `LANE-READ-FAILED` | the session or inventory is broken; recover it before anything else |
| git | `unpushed` > 0 | check the push cadence gates |
| CI | a non-success conclusion | stop the train, fix forward |
| watcher health | `MONITOR-DOWN` | relaunch the named watcher immediately |
| optional board projection | `BOARD-STALE` | when `FLEET_BOARD` is set, pulse the coordinator to run its adapter and regenerate the projection |
| streams | phase counts | look for a phase that is not moving |
| backlog velocity | `VELOCITY-STALL` | find the bottleneck and pulse the coordinator with it, by name |
| blocked column | `STALE-BLOCKERS` | order the dispatch; the blocker already landed |
| blocked column | top unblock levers | prioritize the blocker that frees the most work |
| queue reconciliation | `QUEUE-DRIFT`, `ORPHANED` | have the coordinator re-phase or re-dispatch |

An idle lane with ready work is a failure of the orchestrator, not of the
lane. Keeping every seat busy is the point of the checkpoint.

## Queue reconciliation

**The train queue is computed from the fleet config plus git every tick, never
recalled.** Two queue errors in one afternoon — one approved item silently
missed its batch slot, another was chased after it had already landed and been
pushed — are what put this section in the script.

The check is three assertions:

- A **queued** item's tip must NOT be an ancestor of the seed tip. Queued means
  awaiting landing after approval; `ready` and `review-ready` are not landing
  queue phases. If a queued tip is already on the seed,
  the item already landed and its phase is stale (`QUEUE-DRIFT`).
- A **landed** item's recorded tip MUST be an ancestor of the seed tip. If it
  is not, the recorded tip is a pre-rebase clone SHA. `landedTip` is always
  the post-rebase **seed** SHA captured at land time (`QUEUE-DRIFT`).
- An **active** item must have one of its exact current `agents.*.name` values
  in the live inventory. Never infer ownership from a ticket-name substring:
  derived Herdr names can be truncated and include a stable hash. No exact
  lane means the work is neither running nor queued (`ORPHANED`).

Read the printed `train queue:` line instead of remembering one. Where the
script and your memory disagree, the script is right.

The lane section also prints every pending event as
`event-id[target,age=…,attempts=…]`. Pending is handled-but-unacknowledged, not
`settled-unswept`; use its target, last-send age, attempt count, and the
`1×/2×/4×/8×` backoff schedule to diagnose delivery without polling the
worker again.

## Phase vocabulary

The script classifies phases by stem, so `review-2` counts as `review` and
`bounce-1` as `bounce`. Point the four phase-set bindings at your fleet's own
vocabulary if it differs; see
[orchestrator-config.md](orchestrator-config.md).
