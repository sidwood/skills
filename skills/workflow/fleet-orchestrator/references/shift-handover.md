# Shift handover

Monitors and adopted context die with the session. A handover is what makes
the next shift's first ten minutes recovery rather than archaeology.

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
  lane "{{FLEET_COORDINATOR}}" in session "{{FLEET_SESSION}}" — every
  session-scoped call carries that session.
- Communication contract: references/comms-contract.md is in force —
  five-year-old language, bullets, ⚠️ only when work is stopped on the
  operator. Project additions: {{COMMS_ADDITIONS}}.
- Standing orders live in {{MEMORY_OR_INSTRUCTIONS_LOCATION}}; read them
  before acting.
- Bindings: seed {{FLEET_SEED}}, fleet config {{FLEET_CONFIG}}, state dir
  {{FLEET_STATE_DIR}}, captures {{CAPTURES_DIR}}, board {{FLEET_BOARD}}.

## Monitors — REARM ON TAKEOVER (they died with the last session)
1. Settle monitor: scripts/fleet-monitor.sh, persistent facility, one launch.
2. CI watcher: scripts/ci-watch.sh <full-sha>, one per push.
3. self-eval.sh at every wake; act on findings the same tick.
4. Cron watchdog: one-line prompt pointing at references/watchdog-wake.md;
   list and delete duplicates before creating.

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
2. Rearm all four monitors; confirm heartbeats are fresh.
3. List lanes and adopt them; announce takeover to the coordinator in one prompt.
4. Confirm the first watchdog tick ran clean.
```

## What ages fastest

Queue, lane list, and tips. Everything in the state section is a hint whose
only job is to make the successor's reconciliation cheaper. Identity, law, and
the monitor list are the durable parts — keep them exact.
