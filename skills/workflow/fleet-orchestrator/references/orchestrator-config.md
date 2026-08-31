# Orchestrator configuration

Every project binding is an input. The scripts read them from the environment,
or from a file that `FLEET_ENV` points at
(`scripts/fleet-orchestrator.env.example` is a filled-in template). Nothing is
hardcoded, so the same scripts drive any repository and any fleet.

The fleet config itself (`FLEET_CONFIG`) is the coordinator's file and owns
ticket state, recipes, gate commands, and deployment context. Its schema lives
in the `fleet-coordinator` skill; the orchestrator reads it and never invents
fields.

## Required

| Binding | Meaning |
|---------|---------|
| `FLEET_SESSION` | agent session name the fleet runs in; every session-scoped call carries it |
| `FLEET_SEED` | absolute path to the seed repository (the only thing that pushes) |
| `FLEET_CONFIG` | absolute path to the fleet config the coordinator maintains |
| `FLEET_STATE_DIR` | absolute path for heartbeats, the swept ledger, logs, and the velocity history |

A script that is missing any of these prints all of them and refuses to start.
A monitor running on half a configuration is worse than one that never
started, because its heartbeat implies coverage it does not have.

## Optional

| Binding | Default | Purpose |
|---------|---------|---------|
| `FLEET_COORDINATOR` | `coordinator` | lane the monitor sweeps to and pulses |
| `FLEET_VERDICT_LANE_GLOBS` | `*-review* *-rereview* *-parity*` | lane names whose settles wake the orchestrator |
| `FLEET_SWEEP_INSTRUCTION` | generic sweep wording | text appended to each sweep prompt |
| `FLEET_BOARD` | unset | board or canvas file; set it to enable the `BOARD-STALE` check |
| `FLEET_CAPTURES_DIR` | `$FLEET_STATE_DIR/captures` | where lane captures are written before teardown |
| `FLEET_DEADLINE` | unset | `YYYY-MM-DD HH:MM` local time, for the countdown line |
| `FLEET_CI_RETRIGGER_WORKFLOW` | unset | workflow to trigger once when a push produces no run at all |
| `FLEET_CI_RETRIGGER_REF` | `HEAD` | ref for that trigger |
| `FLEET_POLL_SECONDS` | `60` | settle-monitor poll interval |
| `FLEET_STALL_SECONDS` | `2700` | working-with-frozen-revision threshold for a coordinator stall |
| `FLEET_IDLE_SECONDS` | `300` | coordinator idleness before an idle pulse |
| `FLEET_PULSE_INTERVAL_SECONDS` | `600` | minimum gap between idle pulses |
| `FLEET_CI_POLLS`, `FLEET_CI_POLL_SECONDS` | `40`, `90` | CI watcher budget (default ≈ 60 minutes) |
| `FLEET_MONITOR_STALE_SECONDS` | `180` | settle-monitor heartbeat staleness that means `MONITOR-DOWN` |
| `FLEET_CI_STALE_SECONDS` | `240` | CI watcher heartbeat staleness that means `MONITOR-DOWN` |
| `FLEET_BOARD_STALE_SECONDS` | `600` | board lag behind the fleet config that means `BOARD-STALE` |
| `FLEET_VELOCITY_WINDOW_SECONDS` | `3300` | look-back window for the backlog-velocity comparison |
| `FLEET_CLOSED_PHASES` | `landed superseded withdrawn complete` | phases that count as finished |
| `FLEET_QUEUED_PHASES` | `approved approved-replay-queued landing-replay ready review-ready` | phases that form the landing queue |
| `FLEET_ACTIVE_PHASES` | `implementing review in-review bounce verdict-pending` | phases that must have a live lane |
| `FLEET_BLOCKED_PHASES` | `blocked parked hold` | phases in the blocked column |

Phase sets are matched on the stem, so `review-2` matches `review`.

## Derived paths

Set from `FLEET_STATE_DIR` unless overridden, and shared by all three scripts
so they agree on what is fresh:

- `FLEET_HEARTBEAT` — settle-monitor heartbeat (`fleet-monitor.heartbeat`)
- `FLEET_SWEPT` — swept-lane ledger (`fleet-monitor.swept`)
- `FLEET_LOG` — monitor action log (`fleet-monitor.log`)
- `FLEET_CI_HEARTBEAT` — CI watcher heartbeat (`ci-watch.heartbeat`)
- `FLEET_PUSH_MARKER` — push-in-flight marker (`push-inflight.marker`)
- `FLEET_VELOCITY_LOG` — backlog history (`backlog-velocity.log`)

Keep the state directory outside the seed repository. It is shift-local
scratch, and captures, ledgers, and heartbeats have no business in a diff.
