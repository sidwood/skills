# Verdict discipline

The orchestrator's own hands do four things: capture, rule, land, push. This
file covers the first two. The coordinator's event table (the
`fleet-coordinator` skill) covers dispatch and bounce mechanics; nothing here
repeats it.

## Capture before teardown

1. Run `fleet capture <lane> --event-id <lane@seq> --close`. It reads the lane,
   atomically saves the transcript tail under `FLEET_CAPTURES_DIR`, records the
   parsed result, and then closes the tab.
2. Every capture path is unique. Never overwrite: a re-read that fails after
   the agent deregistered must not clobber the only copy of the output.
3. Only then record the verdict and let the lane be torn down. The config
   event records `capturePath` as durable evidence. The monitor matches the
   exact `eventId` and `agent`, then requires event `closedAt`, event
   `teardownResolvedAt`, kind `resolved-lost-output`, or an exact correlated
   lane marked `closed` or `resolved` before it sweeps the event.
4. If the agent read fails, read the pane. If the pane is gone, the output is
   lost — record it with
   `fleet resolve-event <agent> --event-id <lane@seq> --reason <text>` before
   re-dispatching rather than guessing.
5. A retry of the same event ID and lane does not reread or add a verdict. Add
   `--close` to finish teardown; every next dispatch on the ticket stays
   blocked until prior captured tabs are closed. An already-missing tab is
   idempotent success. Reusing the ID for another lane is an error.

A parse failure stays unacknowledged. Its error, event ID, timestamp, and saved
capture path are recorded as `lastCaptureFailure`, and the command reports the
path so the malformed tail can be corrected without losing evidence. A
successful retry clears that failure record.

Capture and teardown cross separate durable boundaries because the Herdr close
is external. If the process stops between them, the exact capture preserves
the result, while the monitor emits `WAKE teardown <event-id>` after its
default 30-second grace and keeps the event pending until the close is retried
and recorded. A legacy record without an event ID uses a stable synthetic ID
that `fleet capture` attaches during recovery. Missing or invalid capture
timestamps wake immediately. A captured-but-open lane never becomes an
invisible dispatch blocker.

`resolve-event` is exceptional and auditable. With no capture event, it records
`resolved-lost-output`, the exact event ID and agent, a timestamp, and the
supplied reason; it puts the stream on hold and preserves the phase that a
replacement dispatch must restore. If the exact capture already exists but
its close cannot be recovered, it records a separate teardown-resolution
timestamp and reason without pretending the tab was closed. The operator must
first establish the stated failure because the command does not probe it.
Malformed or incomplete output stays pending for correction.

## Reading a verdict

- **Grep only the agent's own output**, below the echoed prompt. The prompt
  contains the words `APPROVE: yes` and `APPROVE: no` in its instructions, so
  a whole-transcript grep reads the instructions back as a verdict.
- **No verdict line means no verdict.** Nudge the lane to re-emit exactly the
  line. Never infer approval from a positive-sounding summary.
- **A viewport loses long reports.** Findings scrolled out of a TUI's buffer
  are not recoverable by scrolling; ask for a re-emit of the findings, or for
  the report to be written to a file, and capture that.
- **Status flaps are not settles.** Oscillation between working and done, or a
  turn that ends before the report, means the agent is mid-thought. Wait for a
  stable settle with output that ends in a verdict line.

## Ruling

- **Scope decides, not taste.** Only in-scope blocking findings can hold a
  slice. Findings tagged deferred are informational and never move the
  verdict; a finding on code the slice did not touch joins the deferral list.
- **Re-reviews are scoped.** A re-review verifies the named findings plus the
  fix diff for regressions. Anything else it reports is a deferral.
- **Same shape twice is a class, not an instance.** Two findings of the same
  shape in consecutive cycles mean the class needs its own ticket; bouncing
  instances of it burns cycles.
- **Rulings travel.** Every overrule and accepted residual is pasted verbatim
  into every later prompt for that ticket. Reviewers have no memory between
  cycles; an unrepeated ruling is re-litigated.
- **The bounce ladder ends with you.** At the bounce cap, re-dispatch the work
  on a stronger model rather than bouncing again; if that fails review too,
  root-cause it personally. A capped ticket must never sit idle waiting to be
  noticed.
- **Escalate rather than invent.** A settle that matches no rule is an
  escalation with the captured tail attached, not an improvised action.

## Reviewer routing

- Reviewer lanes remain orchestrator-owned: their settles wake this role for
  capture and ruling, while routine implementer settles go to the coordinator.
- No model family reviews its own work.
- Spend the most capable (and most rationed) reviewer where a mistake is
  expensive and hard to reverse: data migrations, security and authorization
  seams, complex behavioral parity, and changes to the fleet's own binding
  instructions. Routine diffs get the plentiful reviewer.
- A capacity notice that offers a reset is informational. Treat a family as
  capacity-blocked only when a dispatch actually fails, and record which
  families are blocked so routing stops trying them.
