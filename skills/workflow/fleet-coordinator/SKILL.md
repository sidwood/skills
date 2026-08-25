---
name: fleet-coordinator
description: Use when coordinating a fleet of coding agents against a ticket board — dispatching implementers or reviewers in a Herdr session, handling REVIEW-READY or APPROVE verdicts, bouncing, or landing branch clones — or when the user asks to run the fleet, work the board, or hand the ticket loop to an orchestrator.
---

# Fleet Coordinator

Operate a ticket board as an event loop: every event maps to a table row,
every project binding lives in config, every judgment call escalates to the
user. An unmatched situation stops for escalation — inventing an action is the
one unforgivable failure.

## Configuration contract

1. Locate the project's fleet config (`fleet.json`, or the path the project
   instructions name). It owns every binding: seed repository path, Herdr
   session name, agent recipes, reviewer pairing rules, verification gate
   commands, deployment context, land policy, bounce cap, and per-ticket
   stream state. To create or migrate one, read
   [references/fleet-config.md](references/fleet-config.md).
2. Never hardcode a binding the config owns. Read the seed tip from git
   (`git -C <seed> log --oneline -1`), never from a file.
3. Paste the config's `deploymentContext` block into every prompt you
   dispatch. Severity is judged against that context, never against an
   imagined production load.

## Workflow

1. Watch agent settles (monitor or poll). On each event, find its row below,
   run it, and report. No matching row: stop and escalate.
2. **Implementer settles** → CAPTURE (read the transcript before any
   teardown). Output contains REVIEW-READY with a tip SHA and gate table →
   record it, tear down, dispatch the assigned reviewer using the scoped
   review template. Anything else → escalate with the captured tail.
3. **Reviewer settles** → CAPTURE, then apply the verdict table:
   - APPROVE: yes with no in-scope P0–P2 findings → land (step 5).
   - APPROVE: no with an in-scope P0–P2 and bounce count below the cap →
     bounce: a fix-only prompt naming the findings; the next review verifies
     the fix range only.
   - Bounce cap reached → escalate with a land, split, or kill
     recommendation. Never dispatch past the cap.
   - APPROVE: no where every P0–P2 carries a deferred tag → prompt violation;
     escalate, do not bounce.
   - No APPROVE line → escalate; never infer a verdict.
4. **Blocker lands** → dependents become ready; dispatch them while seats are
   free. An idle seat with ready work is a coordinator failure.
5. **Land** (only from the verdict table or explicit user instruction):
   rebase the clone onto the seed tip if the seed moved and rerun the
   affected checks; fast-forward the seed (`git merge --ff-only`); run the
   config's post-land checks; record the ticket done with verdicts and
   deferrals; unblock dependents. Keep the clone until origin has the
   commits, and never push — the user pushes.
6. Record every state change (phase, tips, verdicts, bounce counts, reviewer
   assignments) in the fleet config and on the board as it happens.

## Review discipline

- The first review of a slice is the only full-range pass (seed tip to branch
  tip). Every re-review verifies the named findings plus the fix-commit diff
  for regressions; a new finding on unchanged code joins the deferral list,
  never a bounce.
- Generate prompts from [references/prompt-templates.md](references/prompt-templates.md)
  with zero unresolved placeholders — refuse to dispatch a prompt containing
  `<`.
- Reviewer prompts carry a scope rule: a tag taxonomy, an explicit
  do-not-hunt list, and "APPROVE: no ONLY when a P0–P2 finding carries the
  in-scope tag".
- User rulings (overrules, accepted residuals) are pasted verbatim into every
  later prompt for that ticket; reviewers have no memory between cycles.
- Two findings of the same shape in consecutive cycles are a defect class:
  open a class ticket instead of bouncing instances.
- The acceptance bar is the ticket's done criteria under the deployment
  context, never "zero findings at maximum effort".

## Rules

- CAPTURE before teardown, always: read the agent transcript, record the
  verdict and findings, and only then close its tab. If the agent read fails,
  read the pane; if that also fails, escalate — never close unread.
- Fresh tab and agent per dispatch; never reuse a settled pane.
- One writer per clone; agents never touch the seed working copy.
- Report in short bullets; the first line is the event and the action taken.

For Herdr commands, dialogs that swallow prompts, and recovery when an agent
deregisters, read [references/herdr-cli.md](references/herdr-cli.md).

## Scripts

Executable helpers live in `scripts/fleet.py`. Config path via `--config` or
`FLEET_CONFIG`. Every mutating subcommand accepts `--dry-run`.

| Workflow step | Command |
|---------------|---------|
| Render implementer / review / bounce prompt | `fleet prompt <ticket> <implementer\|review\|bounce> --out <file>` |
| Capture agent output (before tab close) | `fleet capture <agent-name> [--close]` |
| Board snapshot and next action | `fleet state` |
| Apply verdict table to newest capture | `fleet verdict <ticket> [--commit]` |
| Open tab, start agent, send prompt | `fleet dispatch <ticket> <impl\|review> --prompt-file <file>` |
| Fast-forward seed from approved clone | `fleet land <ticket>` |
| Gate commands for current diff | `fleet gate <ticket>` |

Run unit tests: `python3 -m unittest discover -s scripts/tests`.
