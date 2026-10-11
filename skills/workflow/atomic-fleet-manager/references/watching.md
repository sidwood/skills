# Watching the fleet

The fleet manager cannot be interrupted by a harness; it finds out that
something happened only by being woken. The watcher is that wake-up.

## Arm it

Run this as a background command (in Claude Code, the Bash tool with
`run_in_background`); a foreground run would block the session:

```bash
scripts/watch.sh
```

It polls `scripts/status.sh` every 60 seconds and exits when the set of
agent tabs differs from what it saw at start. That set is every pane in
the workspace that holds an agent, except your own: harnesses, the QA
agent, and any agent you start by hand in a tab of any name (a one-off
reviewer, for example). Until 2026-10-08 only Atomic panes and the tab
labeled `QA` were listed, so a one-off QA agent in a tab called `QA-FABLE`
finished unnoticed. On exit
it prints the lines that changed (`was:` and `now:`) and the full status.
The harness that runs you delivers that exit as a notification, which
starts your next turn.

Options: `--interval SECONDS`, `--timeout SECONDS` (exit with `NO CHANGE`
after that long), `--workspace ID`.

## When it wakes you

1. Read the `was:` and `now:` lines to see which tabs changed.
2. Read each changed pane; a status word is not the story. `working` to
   at-rest can mean finished, paused itself, or failed.
3. Act: land a train, resume a waiting harness, relay a question, hand a
   train to QA, clean up after a verdict.
4. Re-arm the watcher before you end the turn.

## What counts as a change

- A tab moving between `working`, `blocked` and at-rest.
- A harness tab appearing (you launched one) or disappearing (you closed
  one). Launching or closing tabs while a watcher is running therefore
  wakes it; arm it after the batch, not before.
- `idle` and `done` are both at-rest and do not count as different.
- The QA tab starting work. Handing a train to QA while a watcher is
  running wakes it at once, so hand over first and arm the watcher after.

## Pitfalls met in practice

- **The watcher hears Herdr's agent events.** It subscribes to
  `pane.agent_status_changed` on Herdr's socket for every pane in the
  workspace (`scripts/herdr-wait.py`), so a tab that stops or blocks is
  reported within seconds: a Cursor writer or reviewer ending its turn, an
  Atomic run ending or pausing. Its output names what woke it
  (`trigger: EVENT <pane> <state>` or `trigger: poll`). The 60-second poll
  remains for what Herdr does not announce: a tab opening or closing, and a
  headless harness writing its result.
- **Starting is reported late on purpose.** A tab that begins working is
  reported only after it has stayed working for the interval, so a harness
  answering a ping does not wake you twice.
- **A paused or quit run is `blocked`.** `scripts/status.sh` reads the
  Atomic panel: a run held paused after a failed stage, or one that was
  quit, shows as `blocked` with `run paused, resume it`. Resume it as soon
  as the load allows; do not read a tab at rest as a finished run.
- **One watcher at a time.** A second one doubles every notification. If
  one is already running when you want different options, let it fire or
  stop it first.
- **A watcher holds the script path it was started with.** Renaming or
  moving the skill directory breaks a running watcher; re-arm afterwards.
- **A failed poll is not a change.** The script ignores an empty status
  read and keeps waiting.
- **The watcher does not see trains.** Checks you start in the staging
  clone are their own background commands with their own notifications.
- **Long waits are normal.** A complex harness can run for over an hour;
  silence from the watcher means nothing changed, not that it died. To
  check on it without waiting, run `scripts/status.sh`.
- **Do not poll in the foreground.** Sleeping in the main turn blocks the
  user; let the background command do the waiting.

## Watch the load too

- Keep a second background check beside the watcher that exits when the
  1-minute load average passes the core count plus half. Re-arm it after
  it fires, like the watcher.
- When it fires: launch nothing, find what is consuming the CPU, and tell
  whoever started it to stop. Harness runs that report a workflow database
  timeout usually recover themselves once the load falls; answer any that
  ask.
- Never let a run offer to "review directly with subagents" as a way round
  a failed review stage: that puts the writer's model line in the
  reviewer's seat. Have it retry the workflow review.
- Tell the QA agent not to add artificial CPU load when hunting flakes.

## An idle harness with no run is stalled: resume it, do not relaunch it

- A harness at rest whose last line says a run "resumed" or "started", and
  whose status shows no run, is stalled. Do not assume the work continues
  in the background.
- A run that died on the machine (a workflow-database timeout, a dropped
  connection, a provider usage limit) keeps its finished stages. A new run
  repeats them, reviewers included. Recover in this order, moving down only
  when a step fails:
  1. `scripts/resume.sh --issue ID`: the same run, in its own session.
  2. `scripts/resume.sh --issue ID --fresh`: the same run from a new Atomic
     process, for a dead session or a stale login. Close the old tab first;
     Atomic hands a run to another process only after its owner has been
     silent for two minutes, and the script refuses until then.
  3. A new run with `launch.sh --checkout`, whose objective names the
     commits already reviewed and limits review to what changed since. Say
     in the report why 1 and 2 failed.
- `scripts/resume.sh --issue ID --status` prints the run's recorded state
  (`failed`, `blocked`, `paused`, `crashed`, `running`, `completed`), its
  latest stage and its error, from Atomic's workflow database.
- The script refuses above its load limit: a resume into an overloaded
  machine dies the same way.
- Since Atomic 0.9.27 a pause is held in the owning process and the
  stage, not in the run's recorded status, so `--status` reports a paused
  run as `running` (owner alive) or `crashed` (owner gone). For a pause,
  trust the pane's `/workflow status`; resume it in its own session.
- A stage that fails on infrastructure ("Managed PostgreSQL did not answer
  a health check in time") leaves the run held this way: the panel says
  `1 paused` and a resume is refused as "already running in this
  session". `resume.sh` sees the refusal, sends `/workflow quit <run>`
  (which keeps the run resumable) and resumes again. A task view left
  open in the pane swallows typed text; if nothing appears in the chat,
  close the view before sending again.
- A tab at rest is not a finished run. After a load spike, read the panel:
  `paused` with no stage activity means the run needs a resume.
- A provider usage limit needs the user to log in to another account before
  any resume.
- `blocked` on resume means the goal ledger holds a decision that closes
  the run. Read the ledger before choosing step 3.

## "Command aborted" in a harness pane

Atomic delivers a message to a busy stage by aborting the command that
stage has in the foreground. An orchestrator waiting on its writer with
`sleep` shows this every time a progress update or the main chat's
15-minute alignment check arrives; it is harmless there. It is not
harmless for a long command: a suite or the gate in the foreground is
killed by the next message. The launcher tells harnesses to run those in
the background and poll, and a message from the fleet manager has the same
effect, so send one only when it is worth interrupting a poll.


## Changing a script while the fleet runs

Bash reads a script as it goes, through an open file. Editing a script in
place while a harness, the watcher or the gate is running from it makes
that instance read the wrong bytes later. Write the new version beside it
and rename it over the old name (`mv -f name.new name`); running
instances keep the old file, new launches get the new one.

## A pane that starts its own follow-up run

When a run ends at its round limit, the Atomic session in the pane is told the run has completed, and it may decide to start another run in the same clone to fix what the reviewers left. The pane never comes to rest, so its agent status never changes.

`launch.sh` records the run each pane was launched with in `~/.local/state/atomic-fleet/launched.tsv` (pane, issue, run id, time). `status.sh` compares that with the run the pane's BACKGROUND panel shows and reports the row `blocked` with `unexpected run <id>, launched with <id>`, which wakes the watcher.

- Read the first run's `goal-ledger.json` (`status` is `handover`) and the new run's inputs in the workflow database before deciding. Check the writer, the review tier and the clone are the ones you chose, and read what the reviewers left.
- If it is the fix pass you would have launched, let it finish, tell the pane to start no further run, and accept the run by appending a line for it to the launch log.
- If what is left does not merit a pass (no crash, an edge no client reaches, a demand to preserve an accident), tell the pane to quit the run, land the last gated commit, and give the reviewer's open findings to QA to rule on.
- The launch note tells the session to report and stop when its run ends. A session can still ignore it; the comparison above is the safeguard.
