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
harness tabs plus the `QA` tab differs from what it saw at start. On exit
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

- **One watcher at a time.** A second one doubles every notification. If
  one is already running when you want different options, let it fire or
  stop it first.
- **A watcher holds the script path it was started with.** Renaming or
  moving the skill directory breaks a running watcher; re-arm afterwards.
- **A failed poll is not a change.** The script ignores an empty status
  read and keeps waiting.
- **The watcher does not see trains.** Checks you start in the staging
  clone are their own background commands with their own notifications.
- **Long waits are normal.** A frontier harness can run for over an hour;
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

## An idle harness with no run is stalled, not waiting

- When a harness goes to rest, read its last report at once. It is
  finished only if that report says the reviewers approved (or names what
  it is blocked on).
- A harness at rest whose last line says a run "resumed" or "started", and
  whose status shows no run, is stalled. Do not assume the work continues
  in the background. Relaunch a follow-up in its clone straight away.
- On every status read, compare each at-rest harness against what you
  expect: finished and landed, finished and queued for a train, or blocked
  with a question. Anything else needs action now.
