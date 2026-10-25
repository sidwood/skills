# The QA agent

One reviewing agent per project, in its own Herdr tab labeled `QA`. It is
the last check before an issue is called done and the only reviewer that
sees several issues together. Use the strongest model available for it:
the volume is one review per train, and it has caught defects that a
harness's own reviewers approved.

## Start it

Skip this when a tab labeled `QA` already holds a live agent; send it the
standing brief instead if it has not had one.

```bash
herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd <seed> --label QA --no-focus
herdr agent start qa --kind claude --pane <root pane id> -- \
  --model claude-opus-5-5 --effort xhigh --name QA
herdr agent prompt qa "<standing brief>" --wait --timeout 120000
```

- Model and effort are the user's to change; these are the defaults
  (Opus 5.5 at xhigh since 2026-10-06; Fable 5.1 at high before that).
- When the QA agent changes, ask the outgoing one to write a handover
  file first (`.atomic/fleet/qa-handover.md`: live stack, scripts,
  conventions, counts, open findings) and keep its probe scripts under
  `.atomic/fleet/qa-scripts/`; brief the successor to read both.
- Start it in the permission mode the user's other agents in this workspace
  use. Do not add a permission-bypass flag on your own; ask once if the
  mode is unclear, since the QA agent runs test suites and browsers.
- Run `claude --help` when a flag is rejected; the CLI is the authority.

## Standing brief

Send this once, adapted to the project (seed path, tracker, check
commands). Keep it as one message.

```text
You are the QA reviewer for <project>. The fleet manager (the FM tab) orchestrates a fleet of
Atomic harnesses and lands their finished work on the seed (<seed path>) in
batches called trains. You review each train after it lands and is pushed.

For each train I will send: the commit range, which commit belongs to which
issue, and the results of the checks I ran on the combined tip (<type check,
lint, unit, integration>), plus what was not run.

Your review:
1. Read each issue in <tracker>, including any Ruling section, and check
   the diff against its acceptance criteria.
2. Look at the train as a whole: interactions between the issues, and
   anything the combined result breaks.
3. Do not re-run the suites the train already ran. Run what it did not
   cover (<component and browser suites>), and re-run a covered suite only
   for a specific doubt, saying which.
4. Review by commit range. I will not move the seed while you are
   reviewing; say in your verdict when you are finished with the working
   tree.
5. Do not edit code, commit, push, land, or change the tracker.

Report: one verdict per issue (approved, or findings numbered with file
and line and the observable problem), one verdict for the train, and
separately any design question that is the user's to decide. Lead with the
verdicts.
```

## Hand over a train

```bash
herdr agent prompt qa "Train <n> has landed and is pushed: <base>..<tip>. <hash> is <issue> (<what it does>); ... Checks on the combined tip before landing: <results>. Not run: <suites>. The issues are in review in <tracker>." 
```

A prompt sent while the QA agent is working is queued and handled after
its current turn.

## Act on the verdict

- **Train approved:** clean up each issue as
  [landing-train.md](landing-train.md) describes.
- **Issue has findings:** record the accepted findings in the tracker
  issue, then start a follow-up run in that issue's clone with the findings
  as the objective. The fix lands in a later train. That train is not
  sent back to QA (see "One QA review per piece of work").
- **Design question:** bring it to the user with your recommendation.

Read the QA agent's full output from its pane; a summary line is not the
whole list of findings.

## Reading the verdict

- Read the QA agent's report from its session transcript, not from the
  pane: the pane scrolls, truncates long reports and hides the first lines.
- Act only on an explicit verdict line and an explicit statement that it
  is finished with the seed working tree. If either is missing, ask for
  both in two labeled lines and wait.

## When the verdict is "changes needed"

Do these together, in one step:

1. Move the issue back to In Progress in the tracker.
2. Start the fix run in the issue's clone, with the QA finding quoted.
3. Tell the QA agent the fix lands as its own train and will not come
   back for review.

An issue with a harness working on it is In Progress; one landed and
awaiting or under review is In Review; one approved is Done. Check the
board against the fleet whenever a train's verdict arrives.

## One QA review per piece of work

- QA reviews a piece of work once. The fix pass that answers its findings
  lands on its harness's own approval and the gate. It is not sent back to
  QA.
- The reason: a review of every fix finds something new each time, about
  one ticket per review, and the milestone never closes. What QA finds
  outside the reviewed ticket's criteria is already a hardening ticket.
- Ask the user before sending any fix train to QA a second time.

## Tickets QA files

Give QA the milestone rule in its first brief, or it files every follow-up
under the first milestone:

- A follow-up goes in the milestone of the ticket under review.
- Hardening that breaks no user journey goes in the hardening milestone.
- A ticket joins a milestone that is being closed only if it breaks that
  milestone's stated exit condition.
- Each ticket says in one line why it is in its milestone.

Before reporting a milestone complete, list its issues that are not Done
and check each against the milestone's description.

## Probes never reach a real third party

A rule in the brief is not a mechanism. A QA agent told that no probe may
reach an identity provider guarded its browser journeys with a route in
the browser driver; two engines do not run a route for a redirect's second
hop, and eight requests reached the real provider.

When a review touches a sign-in provider, a payment provider, mail or a
model, the brief names the mechanisms, and QA proves them before probing:

- The stack under test cannot name the real service: its client is
  replaced, or its addresses point at a stand-in on the loopback address.
- Every browser is launched with a proxy that does not exist for any host
  off the machine, so an escaped navigation fails instead of leaving.
- The review stack is started with placeholder credentials for the
  provider, never the project's real client id or key, so an escape
  carries nothing of the project's.
- The probe refuses to start unless all of that holds.
- For an API suite, run it once with outbound TLS refused and assert that
  nothing was attempted.
- Interception in the browser is a convenience, never the guard.
- If something does get out, QA says so at the top of its verdict with
  exactly what was sent, and the fleet manager tells the user the same day.

## Handover trains

A train marked as a handover carries the harness's open findings. Ask QA to
check the acceptance criteria as usual and then either finish the open
items in one pass (its fix comes back as its own train) or state plainly
which it could not finish and why. QA raises that with the fleet manager,
who decides with the user; QA does not send the issue back to a harness
itself.

## Measuring the QA agent

`.atomic/fleet/qa-eval/qa-metrics.py <transcript> <label>` extracts
per-train metrics from a QA agent's Claude Code transcript (duration,
verdict, blocking and non-blocking findings, live checks, probe scripts,
tickets filed, tokens where recorded). Run it on the outgoing agent's
transcript before a model change and on the new one's after a few days;
the comparison is the evidence for keeping or reverting the change.


Say in the brief that the staging clone and the harness clones are the
fleet manager's: QA never removes or prunes them. One QA agent removed the
staging clone while tidying before a handover.

## The QA seat under a second Claude account

When the owner has a second Anthropic account with spare allowance, the QA seat can run as Claude Code under it, so reviews cost nothing from the account the fleet manager runs on.

- Use the owner's own alias for that account (for example `claude-work`, which sets `CLAUDE_CONFIG_DIR` and the permission mode). Run it in the QA pane with `herdr pane run <pane> "<alias> --model <model> --effort <level> -n qa"`. `herdr agent start --kind claude` runs the plain executable and would use the first account.
- A pane whose shell is older than the alias answers "command not found" with the whole line: source the aliases file in that pane first.
- The first start in a folder asks whether to trust it, with "No" selected. Read the banner afterwards: it names the model, the effort and the plan.
- Give the seat a queue file, not a single handover, when several units wait: one entry for each unit with its range, handover, report path and a status cell the seat keeps current; tell it to finish an entry before starting the next and not to stop between entries. Collect findings in one section of that file.
- A model line does not review its own work, and QA is a review. Put every unit the seat's own model wrote on hold in the queue and ask the owner who reviews those (another model on the same account, or a seat on another provider).
- Watch the pane for the seat stopping, not for each entry: one wake at the end.

## QA that fixes its own findings

An owner may ask the QA seat to fix what it finds instead of sending each finding to a fix-pass harness (Casefile Crafter, 2026-10-12: a Fable 5.1 xhigh seat on the owner's second account, fixing with Opus 5.5 xhigh subagents inside the same Claude Code session).

- The seat still reviews first and collates every finding; then subagents on another model line fix them in the seat's own clone, one commit per finding, under the repo's commit rules (no attribution trailers, whatever the tool's default). The seat checks each fix with the break that found it, so no line judges its own work.
- It does not fix what needs a ruling, what touches a file a running unit holds, or what is too large for a fix pass; those come back to the FM as before.
- The queue status says so (`done: fixed in place (N; clone; commits; test-only | product)`), and the done-sync must not treat it as approval.
- Landing, as one owner chose it: commits that touch only specs and test support land straight on `main` (fast-forward and push, no gate of their own) when `main` has not moved since the QA clone's base, so later work stacks on them at once and the next train's gate covers them; product-code fixes, and any fix once `main` has moved, ride the next train as an extra clone. A train stacked before a direct push is restarted. Either way the FM closes the tickets after landing with no second review and removes the clone.
