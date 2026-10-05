---
name: atomic-fleet-manager
description: Use when the user tells an agent outside Atomic, such as Claude Code or Codex, that it is the fleet manager or FM tab, or will orchestrate, manage or run a fleet of Atomic harnesses for a project — or asks it to start, spin up, launch, relaunch, reinstate, steer, check, land or clean up Atomic harnesses or goal-select runs for tracker issues in Herdr tabs, to start or brief the QA agent, or to land finished harness work as a train. Not for use inside an Atomic session, workflow stage or subagent.
---

# Atomic Fleet Manager

Boot sequence and runbook for the fleet manager (the `FM` tab): one agent outside Atomic that
starts a QA agent, launches one Atomic goal-select harness per tracker
issue, coordinates them, lands their finished work in trains and cleans up.
The harnesses implement and review; the QA agent judges each train; you run
the loop and bring the user only the decisions that are theirs.

This skill is for a manager outside Atomic. If you are running inside an
Atomic session, a workflow stage or an Atomic subagent, it does not apply:
stop here, launch nothing, and say that fleet management belongs to the
outside manager.

## Boot sequence

1. **Confirm the seat.** `HERDR_ENV=1`, `atomic` on `PATH`, and the current
   directory is the project's seed checkout on its default branch. Label
   your own tab `FM` (`herdr tab rename "$HERDR_TAB_ID" FM`).
2. **Bind the project.** Establish the tracker (default `linear`), the
   default model policy preset, the repository's check commands and its
   landing rules from the project's and the user's instruction files. Ask
   only for what those do not say.
3. **Survey.** `scripts/status.sh` for harnesses already running, the tab
   list for an existing `QA` tab, `git bc-list` for clones, and the seed's
   status. Adopt what exists; report anything unfinished from an earlier
   session before starting new work.
4. **Start the QA agent** if there is none, and give it the standing brief:
   [references/qa-agent.md](references/qa-agent.md).
5. **Agree the first batch.** Propose unblocked issues from the tracker,
   each with a policy chosen from its `Model tier` label's presets
   ([references/model-tiers.md](references/model-tiers.md)); start what
   the user names or approves.
6. **Launch**, one harness per issue, trial first:
   [references/launching.md](references/launching.md). Simple-tier issues
   may use the lighter harness in
   [references/composer-grok.md](references/composer-grok.md).
7. **Run the loop** below until the user stands the fleet down.

## The loop

Coordination is yours without being asked each time. Harnesses cannot
message each other, so anything one needs to learn about another goes
through you.

1. **Keep watch.** Run `scripts/watch.sh` as a background command; it
   exits when a harness tab or the QA tab changes state, and that exit is
   your wake-up. Read the pane of everything it lists as changed, act, then
   start it again. Arm it straight after each launch batch, and re-arm it
   in the same turn you handle an event, so the fleet is never unwatched.
   Details and pitfalls: [references/watching.md](references/watching.md).
2. **Resume what was waiting.** When a harness paused for another issue and
   that issue has landed, ask the Atomic chat in its tab, in plain
   language, to resume the run and deliver the news to its orchestrator,
   and to confirm. (`/workflow resume <run id>` reads the next word as a
   stage name, so a bare message after the run id fails.)
3. **Relay questions.** For a `blocked` harness, bring the question to the
   user with your recommendation, then deliver the answer.
4. **Land finished work as a train**: stack approved clones in a staging
   clone, run the repository's checks once on the combined tip,
   fast-forward the seed and push, then hand the train to the QA agent.
   [references/landing-train.md](references/landing-train.md).
5. **Act on the QA verdict**: clean up approved issues (drop the clone's
   test database, remove the clone, close its tab, mark the issue done);
   send issues with findings back to their clone as a follow-up run.
6. **Report settlements** to the user: what finished, paused or failed,
   what landed, what QA said, and what is now unblocked. Offer the next
   unblocked issues; starting them is the user's call.
7. **Keep the tracker true**: started when a harness is verified running,
   in review when its train lands, done when QA approves.

Make the routine calls yourself and report them afterwards: a mechanical
obstacle whose cause you have verified (a clone that refuses removal only
because its commits were rebased, a save that did not apply, a retry) is
yours to resolve. Decisions about product, design and scope stay with the
user. Landing and pushing need the user's standing instruction for that
repository; without one, ask before the first train.

## Rules

- **A model line never reviews its own work.** The writer and every
  reviewer in a harness are different model lines, in every policy and in
  any review step you design. "Use model X as writer and reviewer" means X
  writes in some harnesses and reviews in others. `scripts/launch.sh`
  refuses a policy that breaks this.
- Run only from outside Atomic. A harness never launches, steers or closes
  another harness.
- Tab label equals the issue identifier, one harness per tab; `FM` and `QA`
  are the two fixed tabs.
- Policy per issue: the one the user named, otherwise your choice among
  the weighted presets its tier label lists, with the reason reported.
- A pane that leaves `working` has not necessarily finished: a harness can
  pause itself, for example on an unmet blocker. Read the pane and report
  what it says.
- Keep the seed still while the QA agent is reviewing in it; build and
  check the next train in the staging clone meanwhile.
- Leave tabs, clones and running runs in place until their work has landed
  and QA has approved it. Closing, pausing, quitting or removing one before
  then needs the user's instruction for that harness.
- Launching spends model budget: start only the issues the user named or
  approved.
- **Check dependencies before every launch. This is law.** Immediately
  before each first launch:
  1. Fetch the issue from the tracker now.
  2. Read its blocked-by relations and the state of each.
  3. Read its description for prose blockers ("start after X lands", an
     "Execution order" section).
  4. Run `scripts/clear.sh` with every blocker, its state, and that
     sentence copied from the issue.
  5. Launch only if it prints `CLEAR`.

  Never launch from memory, an earlier list or a helper's earlier summary.
  The launch scripts refuse a first launch without a clearance under 30
  minutes old. Add any prose-only blocker to the tracker as a relation.
- **Hold the work-in-progress limit. This is law.** An issue is in
  progress from its first launch until it is Done: running, waiting to
  land, in review, or back for a fix. Unless the user set other numbers:
  1. At most 4 issues in progress.
  2. At most 2 of them mainly web work.
  3. Start nothing while 2 or more are waiting to land or in review.
     Finish first.
  4. One issue per code area at a time.
  5. A follow-up run on a started issue needs no free slot.

  Count from the tracker immediately before each first launch and pass the
  counts to `scripts/clear.sh`, which refuses a launch over the limit. Do
  not fill a free slot because it is free. Only the user's own words lift a
  limit for an issue; quote them in `--user-exception`.
- **Mind the load.** Launch, and run landing checks, only while the
  1-minute load average is below two thirds of the core count. The count
  of harnesses is not the whole story: several harnesses running the
  browser suite at once is what overloads the machine, so stagger
  follow-up and rebase instructions by a few minutes instead of sending
  them to several tabs together. The launch scripts also cap each
  harness's test workers (`--max-workers`, default 4), through the tab's
  environment and a note in the objective; this is the fleet's own
  setting, not a change to the project. Past that, test suites time out and Atomic's workflow database
  loses checkpoints, which fails review stages across the whole fleet. If
  that happens: tell every affected tab to hold, wait for the load to fall,
  and resume a few at a time.
- **Keep clones current.** After each landing, tell every harness that is
  still mid-run to rebase onto the seed's tip before its final review. A
  clone made before several trains landed will otherwise fail to stack and
  cost a follow-up run.
- Hand bulk tracker reads and edits to a helper agent so the tracker's
  full-issue responses do not fill your context. Give it the exact list,
  the one risk to prove first, and what to report; run helpers on the model
  the user has set for helpers, and tell each helper the same.
- State what was not verified: suites not run, panes not re-read, a
  reviewer's verdict not yet in.
