# Shift handover

Harness-launched monitors can die with their launching process; the local
OS watchdog, shared Herdr session, and project workspaces persist. A handover is
what makes the next shift's first ten minutes recovery rather than archaeology.

Two hands never steer at once: the outgoing orchestrator stops touching the
fleet the moment the successor announces takeover, and its last act is to
confirm the successor's first checkpoint ran clean.

## Handover template

Fill every placeholder; delete nothing. State is written to be **verified,
not trusted** — the successor re-derives it with `scripts/self-eval.sh`.

```text
# ORCHESTRATOR HANDOVER — {{FLEET_NAME}}

Written {{TIMESTAMP}} (run `date`; never infer it). Reason: {{WHY_HANDOVER}}.
The successor takes full fleet command, including {{OWNED_DUTIES}}.

## Identity and law
- You are the orchestrator. {{OPERATOR}} is the operator. The coordinator is
  lane "{{FLEET_COORDINATOR}}" in workspace "{{FLEET_WORKSPACE}}", inside
  {{FLEET_SESSION_OR_DEFAULT}}. Inventory and new tabs stay in that workspace.
- Communication contract: references/comms-contract.md is in force —
  five-year-old language, bullets, ⚠️ only when work is stopped on the
  operator. Project additions: {{COMMS_ADDITIONS}}.
- Standing orders live in {{MEMORY_OR_INSTRUCTIONS_LOCATION}}; read them
  before acting.
- Bindings: workspace {{FLEET_WORKSPACE}}, optional shared session
  {{FLEET_SESSION_OR_UNSET}}, seed {{FLEET_SEED}}, ignored runtime directory
  {{FLEET_STATE_DIR}}, fleet config {{FLEET_CONFIG}}, captures {{CAPTURES_DIR}},
  optional board projection {{FLEET_BOARD_OR_UNSET}}.

## Monitors — VERIFY ON TAKEOVER (rearm only missing processes)
1. Settle monitor: scripts/fleet-monitor.sh, persistent facility, one launch.
2. CI watcher: scripts/ci-watch.sh <full-sha>, one per push.
3. self-eval.sh at every wake; act on findings the same tick.
4. Local watchdog: {{OS_JOB_LABEL}}, destination {{ORCHESTRATOR_THREAD_ID}},
   state {{WATCHDOG_STATE}}, last healthy run {{WATCHDOG_LAST_RUN}}.
   Verify its job and issue delivery; do not create a duplicate.
   Periodic AI polling remains disabled; healthy local checks use no tokens.

## Process law in force
- {{LANDING_TRAIN_RULES}}
- {{PUSH_CADENCE_GATES}}
- {{BOUNCE_LADDER}}
- {{REVIEWER_ROUTING}}
- {{OPEN_RULINGS_VERBATIM}}

## State at {{TIMESTAMP}} (verify with self-eval.sh; do not trust this)
- Remote tip: {{REMOTE_TIP}} — carries {{WHAT_IS_DEPLOYED}}.
- Seed tip: {{SEED_TIP}} — {{UNPUSHED_SUMMARY}}, push gated on {{GATE}}.
- Queue (computed at write time): {{QUEUE}}.
- In flight: {{LANE_BY_LANE}}.
- Blocked: {{BLOCKED_WITH_BLOCKERS}}.
- Awaiting the operator: {{OPERATOR_DECISIONS}}.

## Operator plan, in their own words
{{PLAN_ORDERED}}

## Takeover sequence
1. Run `date`, then self-eval.sh; reconcile every drift line before dispatching.
2. Rearm the singleton settle monitor first; its startup pass reconciles
   pending events, settled lanes, and owned lanes missing from inventory.
   Rearm the other monitors and confirm heartbeats are fresh.
3. List lanes and adopt them; announce takeover to the coordinator in one prompt.
4. Confirm the local watchdog check was silent and did not invoke a model.
```

## What ages fastest

Queue, lane list, and tips. Everything in the state section is a hint whose
only job is to make the successor's reconciliation cheaper. Identity, law, and
the monitor list are the durable parts — keep them exact.
