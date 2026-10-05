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
  --model claude-fable-5-1 --effort high --name QA
herdr agent prompt qa "<standing brief>" --wait --timeout 120000
```

- Model and effort are the user's to change; these are the defaults.
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
  as the objective. The fix lands in a later train.
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
3. Tell the QA agent the fix will arrive as its own train.

An issue with a harness working on it is In Progress; one landed and
awaiting or under review is In Review; one approved is Done. Check the
board against the fleet whenever a train's verdict arrives.

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
