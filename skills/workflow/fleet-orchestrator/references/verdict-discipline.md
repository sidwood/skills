# Verdict discipline

The orchestrator's own hands do four things: capture, rule, land, push. This
file covers the first two. The coordinator's event table (the
`fleet-coordinator` skill) covers dispatch and bounce mechanics; nothing here
repeats it.

## Capture before teardown

1. Read the lane transcript tail to a capture file under the captures
   directory (`FLEET_CAPTURES_DIR`), named for the lane.
2. If a capture file already exists, write a suffixed one (`-2`, `-3`). Never
   overwrite: a re-read that fails after the agent deregistered clobbers the
   only copy of the output with an error message.
3. Only then record the verdict and let the lane be torn down.
4. If the agent read fails, read the pane. If the pane is gone, the output is
   lost — say so and re-dispatch rather than guessing.

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

- No model family reviews its own work.
- Spend the most capable (and most rationed) reviewer where a mistake is
  expensive and hard to reverse: data migrations, security and authorization
  seams, complex behavioral parity, and changes to the fleet's own binding
  instructions. Routine diffs get the plentiful reviewer.
- A capacity notice that offers a reset is informational. Treat a family as
  capacity-blocked only when a dispatch actually fails, and record which
  families are blocked so routing stops trying them.
