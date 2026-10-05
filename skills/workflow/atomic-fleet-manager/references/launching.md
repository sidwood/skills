# Launching, following up and steering

## Launch a batch

1. **Check every issue before it starts.** Read the issue from the tracker,
   including its blockers and any execution-order notes, at launch time.
   Start an issue only when each blocker is done. Keep two issues that edit
   the same files out of the same batch, and tell the user when two running
   issues will both add a migration. Report an unmet blocker and let the
   user decide; a recalled classification is not a blocker check.
2. **Pick the policy** for each issue from its tier label, unless the user
   named one: [model-tiers.md](model-tiers.md).
3. **Trial first.** For the first launch of a session, start one issue,
   verify it (step 5) and show the user before starting the rest.
4. **Launch one at a time** from the seed, which must be clean and on its
   default branch because a new clone copies its committed HEAD only:

   ```bash
   scripts/launch.sh --issue TUS-150 --policy opus-astra
   ```

   The script creates the tab, starts `atomic`, submits the `/workflow`
   command with `key=value` inputs so no picker opens, and prints `tab`,
   `pane`, `run_id`, `policy` and `state`. Run it once per issue, in
   sequence, so clones are not created concurrently. Add `--resolve-only`
   to preview the models and clone path without starting any work.
5. **Verify each launch.** A harness counts as running when the script
   printed a `run_id`, the pane's state is `atomic working`, and the clone
   `<seed>.goal-<issue>-<hash>` exists beside the seed about a minute
   later. `scripts/status.sh` lists every Atomic pane in the workspace with
   its progress line.
6. **Update the tracker.** Move the issue to its started state only after
   step 5 passes, then read the returned status; a save can return without
   applying, so retry until the status reads started.
7. **Report the roster**: issue, tab, clone, policy, run id and state for
   every harness, plus anything started against an unmet blocker.

When `launch.sh` fails after creating a tab, read that pane before
retrying, and reuse or report the tab instead of creating a second one.

## Follow-up run after review findings

Continue in the same clone so its commits are kept:

```bash
scripts/launch.sh --issue TUS-144 --policy glm-astra \
  --checkout app.goal-tus-144-f3aff23b \
  --objective "Follow-up after QA review of <commits>. Keep that work and fix: (1) ... (2) ..."
```

- Read the reviewer's full findings from where they were written; a
  one-line summary relayed by the user is not the whole list.
- Put every required fix in `--objective`, numbered, naming files and the
  observable result. Leave the acceptance criteria unset so the issue's own
  criteria remain the contract.
- Keep open design questions out of the objective and put them to the user.
- Record the accepted findings and any new ruling in the tracker issue, so
  the next reviewer judges against them.

## Steering a running harness

Send the instruction to the Atomic session in that issue's tab, in plain
language: name the run id, state every ruling in one message as numbered,
self-contained instructions, ask for delivery to the run's orchestrator,
and ask it to wait for the orchestrator's acknowledgement. A message
interrupts the stage that receives it, so send one message per decision.
Read the pane until the acknowledgement appears, then relay what was
acknowledged, including anything the orchestrator added.

```bash
herdr pane send-text <pane> "<instruction>" && herdr pane send-keys <pane> Enter
```

When a ruling changes scope or acceptance, ask for it to be broadcast to
every stage of the run, current and future, so reviewers hold it too.

For `/workflow` syntax, goal-select inputs, the `single` then `chain` mode
label, run-control commands and how a steering message reaches a stage,
see [atomic-workflow-cli.md](atomic-workflow-cli.md).

## Clearance comes first

`launch.sh` and `launch-composer-grok.sh` refuse a first launch unless
`scripts/clear.sh` wrote a clearance for the issue in the last 30 minutes:

```bash
scripts/clear.sh --issue TUS-58 \
  --blocker TUS-37=Done --blocker TUS-149=Done --blocker TUS-51=Backlog \
  --execution-order "Start after TUS-37, TUS-149 and TUS-51 land." \
  --area "web Outline stage" \
  --in-progress 3 --finishing 1 --area-clash none \
  --web --web-in-progress 1
# NOT CLEAR: TUS-58 waits for: TUS-51=Backlog
```

The last three lines are the work-in-progress limit. Count from the
tracker now, not from the tab list:

- `--in-progress`: issues started and not Done (In Progress plus In
  Review), not counting this one.
- `--finishing`: of those, the ones waiting to land or in review.
- `--area-clash`: an in-progress issue in the same code area, or `none`.
- `--web` with `--web-in-progress`: for an issue that is mainly web work.

The script refuses at 4 in progress, at 2 finishing, at 2 web issues, or
on an area clash (`--wip-limit`, `--finishing-limit`, `--web-limit` change
the numbers when the user sets others). `--user-exception "<their words>"`
records the user lifting a limit for this issue; it never excuses a
blocker.

Pass one `--blocker` for every blocked-by relation and for every issue the
description says to start after, each with the state the tracker shows
now. `--execution-order` is that sentence copied from the issue, or `none`
once you have read the whole description and found no such sentence. The
script cross-checks the two: an issue named in the sentence with no
`--blocker` is an error. Follow-up runs in an existing clone (`--checkout`)
need no clearance.

Pass only start conditions in `--execution-order`. Leave out sentences
that mention other issues without making them a condition ("can run in
parallel with X", "file collision with Y"): the script reads every issue
named there as a blocker and will refuse. After a launch command, read its
output and confirm a run id was printed before telling anyone, or the
tracker, that the issue started.
