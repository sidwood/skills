# Orchestrator configuration

The scripts read project bindings from the environment or from a file that
`FLEET_ENV` points at (`scripts/fleet-orchestrator.env.example` is a template).
The project workspace and seed are explicit; the Herdr session name is
optional. Runtime files default under the seed's gitignored `temp/fleet/`
directory.

The fleet config itself (`FLEET_CONFIG`) is the coordinator's file and owns
ticket state, recipes, gate commands, and deployment context. Its schema lives
in the `fleet-coordinator` skill; the orchestrator reads it and never invents
fields.

## Required

| Binding | Meaning |
|---------|---------|
| `FLEET_WORKSPACE` | Herdr workspace ID dedicated to this project; every inventory is filtered to it and every new tab targets it |
| `FLEET_SEED` | absolute path to the seed repository (the only thing that pushes) |

A Herdr-facing script that is missing either binding refuses to start. A
monitor running on half a configuration is worse than one that never started,
because its heartbeat implies coverage it does not have.

Inside a Herdr-managed pane, `FLEET_WORKSPACE` defaults to the injected
`HERDR_WORKSPACE_ID`. Outside Herdr, set it explicitly to the project's
workspace ID.

## Optional

| Binding | Default | Purpose |
|---------|---------|---------|
| `FLEET_SESSION` | unset | shared named Herdr session; when absent, commands use Herdr's default session |
| `FLEET_STATE_DIR` | `<seed>/temp/fleet` | runtime directory; when inside the seed it must be gitignored |
| `FLEET_CONFIG` | `$FLEET_STATE_DIR/fleet.json` | fleet config the coordinator maintains |
| `FLEET_COORDINATOR` | `coordinator-<workspace-id>` | workspace-unique lane that receives routine settle events |
| `FLEET_VERDICT_LANE_GLOBS` | `*-review* *-rereview* *-parity*` | compatibility routing when an old agent record has no `role`; current `review` records route by role |
| `FLEET_SWEEP_INSTRUCTION` | generic sweep wording | text appended to each sweep prompt |
| `FLEET_BOARD` | unset | external adapter's projection file; set it only to enable the `BOARD-STALE` check |
| `FLEET_CAPTURES_DIR` | `$FLEET_STATE_DIR/captures` | where lane captures are written before teardown |
| `FLEET_DEADLINE` | unset | `YYYY-MM-DD HH:MM` local time, for the countdown line |
| `FLEET_CI_RETRIGGER_WORKFLOW` | unset | workflow to trigger once when a push produces no run at all |
| `FLEET_CI_RETRIGGER_REF` | `HEAD` | ref for that trigger |
| `FLEET_POLL_SECONDS` | `10` | local settle-monitor poll interval; healthy polls produce no model-visible output |
| `FLEET_ACK_TIMEOUT_SECONDS` | `120` | base acknowledgement timeout; retries back off at `1×`, `2×`, `4×`, then `8×` |
| `FLEET_TEARDOWN_GRACE_SECONDS` | `30` | delay before an unclosed capture wakes the orchestrator; missing or invalid timestamps wake immediately |
| `FLEET_STALL_SECONDS` | `2700` | window the coordinator's transition sequence must stay frozen, with no spinner seen, before a stall is declared |
| `FLEET_CI_POLLS`, `FLEET_CI_POLL_SECONDS` | `40`, `90` | CI watcher budget (default ≈ 60 minutes) |
| `FLEET_MONITOR_STALE_SECONDS` | `30` | default heartbeat-staleness threshold that means `MONITOR-DOWN` |
| `FLEET_CI_STALE_SECONDS` | `240` | CI watcher heartbeat staleness that means `MONITOR-DOWN` |
| `FLEET_BOARD_STALE_SECONDS` | `600` | configured projection lag behind fleet state that means `BOARD-STALE` |
| `FLEET_VELOCITY_WINDOW_SECONDS` | `3300` | look-back window for the backlog-velocity comparison |
| `FLEET_CLOSED_PHASES` | `landed superseded withdrawn complete` | phases that count as finished |
| `FLEET_QUEUED_PHASES` | `approved approved-replay-queued landing-replay` | phases that form the landing queue |
| `FLEET_ACTIVE_PHASES` | `implementing review in-review bounce` | phases that must have a live lane |
| `FLEET_BLOCKED_PHASES` | `blocked parked hold` | phases in the blocked column |

Phase sets are matched on the stem, so `review-2` matches `review`.

Use one long-lived Herdr session and create one workspace per project. Record
the same workspace ID in `fleet.json` and `FLEET_WORKSPACE`. A named session,
when chosen, is shared by projects rather than named after one project. If no
name is configured, omit `FLEET_SESSION`; the scripts deliberately omit
`--session` and let Herdr select its default session. Inside a Herdr-managed
pane, commands retain the inherited session.

## Derived paths

Set from `FLEET_STATE_DIR` unless overridden, and shared by all three scripts
so they agree on what is fresh:

- `FLEET_HEARTBEAT` — settle-monitor heartbeat (`fleet-monitor.heartbeat`)
- `FLEET_SWEPT` — acknowledged event-ID ledger (`fleet-monitor.swept`)
- `FLEET_PENDING` — durable at-least-once delivery queue
  (`fleet-monitor.pending`)
- `FLEET_DELIVERY_FAILURES` — deduplicated delivery alarms
  (`fleet-monitor.delivery-failures`)
- `FLEET_MONITOR_LOCK_FILE` — process-lifetime singleton lock
  (`fleet-monitor.lockfile`)
- `FLEET_LOG` — monitor action log (`fleet-monitor.log`)
- `FLEET_CAPTURES_DIR` — agent transcript captures (`captures/`)
- `FLEET_CI_HEARTBEAT` — CI watcher heartbeat (`ci-watch.heartbeat`)
- `FLEET_PUSH_MARKER` — push-in-flight marker (`push-inflight.marker`)
- `FLEET_VELOCITY_LOG` — backlog history (`backlog-velocity.log`)

Keep the state directory under the seed's ignored `temp/` directory by
default. An explicit path outside the seed remains supported. A board is not
created or required: set `FLEET_BOARD` only when an external adapter maintains
a projection that self-eval should check.
