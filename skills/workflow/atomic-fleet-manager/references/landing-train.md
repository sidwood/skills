# Landing train

Land finished harness work in batches from outside Atomic. Each harness
already verified its own change; the train verifies the combination once.
First run on 2026-10-04 (two trains, four issues).

## Build

1. Take every harness that finished with all reviewers approving and a
   clean clone. Order them so an issue lands after the issues it depends on.
2. Make one staging clone from the seed, reused for later trains:

   ```bash
   git bc-add --offline <seed> train
   ```

   The repository's `bc.postadd` installs dependencies and prepares the
   staging clone's own test database.
3. Point the staging branch at the seed's tip, then stack each issue's
   commits onto it:

   ```bash
   git -C <staging> fetch <seed> <default-branch>
   git -C <staging> checkout -B train-N FETCH_HEAD
   git -C <staging> fetch <clone> <clone-branch>
   git -C <staging> rebase --onto train-N <clone-base> FETCH_HEAD
   git -C <staging> checkout -B train-N HEAD
   ```

   `<clone-base>` is the seed commit the clone was made from. Rebase only;
   seed history stays linear.

## Check

**One full gate per piece of work, on the train (owner's ruling, Casefile Crafter, 2026-10-16).** Writers do not run the full gate. Each writer round ends:
- with a rebase onto the seed's latest main;
- then the writer's check: install, database reset, typecheck, lint, unit and integration (`check.sh`, ending `CHECK_OK`);
- then the writer's own browser specs.

The end-to-end and component suites run only on the train. Why:
- The full gate took about 55 minutes and ran at least twice per unit.
- Trains queued behind harness gates for the shared slots.
- Train failures came from units built on stale bases meeting newer main, not from the units' own code; the writer's rebase catches those first.

Run the repository's own gate once on the staging tip, from the staging
clone's root: type check, lint, unit and integration suites. Record the
counts. Say plainly which suites were not run (for example end-to-end).

Run long gates in the background and chain the commands with `&&` so a
failure stops the run, and end the chain with a marker such as
`&& echo GATE_OK`. Land only when the output contains that marker: a
command placed after the chain (printing test counts, say) can make the
whole run exit 0 even though a check failed.

## Land

**Land with a script that stops before pushing when the fast-forward fails** (Casefile Crafter: `.atomic/fleet/fm-scripts/land.sh <train>`). Never pipe the merge into anything: on 2026-10-16, `git merge --ff-only FETCH_HEAD | tail -1 && try-push.sh` hid a refused fast-forward, because the pipe's exit status was `tail`'s. The push then sent a commit someone else had just made on the seed. Someone else may commit on the seed: when `main` is no longer the train's base, restack the train onto the new tip.

1. Confirm the seed is on its default branch with a clean tree. An
   uncommitted change in the seed stops the train; resolve it first.
2. If the seed moved since the stack was built, rebase the train onto the
   new tip. Re-run the gate unless the new commits cannot affect it (a
   documentation-only commit).
3. Fast-forward and push, with hooks on:

   ```bash
   git -C <seed> fetch <staging> train-N
   git -C <seed> merge --ff-only FETCH_HEAD
   git -C <seed> push origin HEAD
   ```

4. Move each landed issue to its review state in the tracker.
5. Resume any harness that paused waiting for an issue in this train.

## When an issue does not fit

- **Rebase conflict:** abort the rebase, leave the issue out of this train,
  and send it back to its own clone as a follow-up run whose objective is to
  rebase onto the seed and resolve the conflict.
- **Gate fails:** find the issue that breaks it by dropping issues from the
  stack one at a time, land the rest, and bounce that issue with the failing
  output in the objective.
- **Two migrations:** land one; the other regenerates its migration on the
  new seed tip in a follow-up run.

## Review in aggregate

After the push, prompt the reviewing agent once per train: the commit
range, which commit belongs to which issue, what the gate covered and what
it did not, and a request for one verdict per issue plus one for the train
as a whole.

Do not move the seed while the reviewer is running checks in it. Either
wait for its verdict before landing the next train, or have it review in
its own clone. If the seed did move under a running review, tell the
reviewer at once which commit to judge and what changed.

## Clean up after approval

When the reviewer approves a train, for each issue in it:

1. Confirm origin has the commits: `git -C <seed> branch -r --contains <commit>`.
2. In the issue's clone, drop its test database with the repository's
   command (for example `pnpm db:test:drop`).
3. Remove the clone with `git bc-rm` (read `git bc-rm -h` first). It refuses
   dirty trees and clones holding commits found nowhere else; on a
   refusal, find the cause with the check below before deciding.
4. Close the issue's Herdr tab: `herdr tab close <tab id>`.
5. Move the issue to its done state in the tracker.

A rebased commit has a new hash, so `git bc-rm` may refuse because it sees
the clone's original commits as found nowhere else. Settle that yourself:

```bash
git -C <seed> fetch <clone> <clone-branch>
git -C <seed> cherry <default-branch> FETCH_HEAD
```

- Every line starts with `-`: each clone commit has an equivalent patch on
  the seed's branch, so the refusal is only the rebase. With a clean clone
  tree and the landed commits on origin, remove it with
  `git bc-rm <clone> -f -y` and mention it in the report. Do not ask.
- Any line starts with `+`: that commit's patch is not on the seed. Compare
  it with the landed commit of the same subject (`git range-diff`); when the
  only difference is context from the rebase, force-remove as above.
  Otherwise keep the clone and report the commit as unlanded work.
- A dirty tree is never a rebase artifact: keep the clone and report it.

A harness can leave a dev server running in its clone, which recreates
cache files and makes the removal fail with "Directory not empty". Find it
with `ps` filtered on the clone name and stop that process before running
`git bc-rm`. If files still remain afterwards, tell the user the path and
leave the deletion to them; do not script a recursive delete.



Keep the staging clone for the next train. Leave rejected issues' clones
and tabs in place for the follow-up run.

## Tickets that carry a migration

Two tickets written at the same time each add a migration, and each edits the
same journal and the same module lists, so whichever lands second no longer
stacks. Landing them one at a time makes every one bounce off the one before.

- When a harness finishes, check its last commits for files under the
  migrations directory before choosing a train.
- If another migration ticket is finished or about to finish, do not land
  them separately. Start one harness in one of the clones with an objective
  to: rebase its own commits onto the seed's tip, fetch and cherry-pick the
  other ticket's commits from the other clone, regenerate each migration with
  the repository's generate command (never hand-merge generated meta files),
  and run the suites once. Land the result as one train and report the
  commits per ticket.
- Hold every other train that touches those files until that one has landed.
- Do not resolve the conflict yourself, however small, when the QA agent is
  on your own model line: your change would then be reviewed by its own line.
  Give it to a harness whose writer is a different line.

## When the seed may move

- Move the seed only after the QA agent's report says it is finished with
  the working tree. Read the report; do not rely on the pane's status.
- A QA agent with background runs still going shows as idle. If its last
  message mentions runs in progress, the seed stays still.
- A harness must never push or change the seed. If one does, have the QA
  agent review those commits as their own train and run the checks on that
  tip before anything else lands.

## Cleanup is one command

After the QA agent approves a train, remove each of its harnesses with
`scripts/cleanup.sh --clone <dir> --tab <tab>`. It refuses, and removes
nothing, unless every commit in the clone is on the remote default branch.
Do not drop the database, close the tab or remove the clone by hand first.

## Chromium-only component failures mean another checkout's servers

A gate that fails only in Chromium, only in component specs that touch the
API, on a change that cannot have caused it, overlapped another checkout's
e2e stage. A component spec with an unstubbed read reaches whatever serves
the app's fixed ports, and Chromium resolves `localhost` to `127.0.0.1`.
Compare the two gates' log times before reading any test.

- The gate template holds the e2e lock for the component suite, so the two
  stages never overlap across checkouts. Keep that until the project's
  component specs can reach no real address.
- A dev server a harness starts by hand on those ports does the same; the
  lock does not cover it.
- Run the train again; do not weigh the failures.

## Check the commits themselves before pushing

A gate proves the code. It says nothing about the commits. Before every
push, over the stacked range:

- No message names a tracker issue. Match the tracker's own key exactly
  (`TUS-123`); a loose "letters, dash, digits" pattern stops a train on
  `UTF-8` or `SHA-256`.
- No attribution: no trailer, and no agent as author or committer.
  `git log --format='%an|%cn' <base>..HEAD | sort -u` prints one line, the
  owner's. A commit made on a remote machine and rebased here keeps its
  foreign author, and the host shows it as two people.
- Where the repo has a message hook, run it over each stacked commit: a
  hook never sees a commit that was rebased or made where hooks were off.
- Better still, give the repo a pre-push hook that does all three, so
  the seed's own push is the gate.

## A run that ends `handover`

A run that uses its review rounds without quorum ends `handover`, with its
open findings listed in the final report. It is not a failure:

1. Stack and gate it like an approved run.
2. Land it, and give QA the open-findings list with the train, marked as
   the harness's unresolved items.
3. QA finishes the open items in one pass when it can, and says so in its
   verdict; its fix lands as its own train through the same gate.
4. When QA cannot finish them, it says why; take that to the user and
   decide together whether the issue goes back to a harness (with the
   findings as the objective), moves tier, or is reshaped.

`needs_human` is different: the orchestrator produced no work or the
reviewers could not run. Read the pane and the ledger before anything else.

## The gate is one script, shared with the harnesses

`templates/gate.sh` is the project's landing gate: install, database
reset, typecheck, lint, unit, integration, the full e2e suite through the
locked `e2e-check.sh`, and the whole component suite with two workers,
ending in `GATE_OK`. Copy it to the seed's `.atomic/fleet/gate.sh` and
adapt the commands once per project. `templates/train.sh` stacks a
clone's commits onto the seed tip in the staging clone and runs that
gate; `EXTRA_CLONES="dir=base ..."` stacks several finished issues into
one train. The launcher tells every harness to run the same gate on its
clone as its final step and to report approved only on `GATE_OK`, so a
train rarely fails the gate for something the harness could have seen.

### When the train fails a test the writer's gate passed

The code is the same, so the difference is timing or shared state. Find
the cause before running the gate again:

1. Run the failing file alone in the staging clone a few times. Passing
   alone and failing in the gate points at load: the gate runs the unit
   suites side by side, so a file takes longer than it does alone.
2. Read what the failing assertion received. A value that the failing
   test's own fixture cannot produce came from another test.
3. Reproduce it on purpose, for example with a wait forced into the test,
   so the fix can be shown to fail first.
4. Fix the cause in the clone as its own commit and run the train again.
   Tell the QA agent that no reviewer has seen that commit.

A second gate run that happens to pass leaves the fault on the default
branch, where it fails a later train at random.

Seen 2026-10-08: a spec made a new store container per test and never
disposed it; each kept a five-second autosave timer, and every test used
one storage key. The file passed alone in three seconds and failed in the
gate at 5.3.

## Follow-ups are simple-tier

A follow-up run in an existing clone (`launch.sh --checkout`) is small
work on code already reviewed: a rebase, a gate failure, a QA finding. The
launcher gives it the simple tier (one reviewer) unless `--tier` says
otherwise, tells it to run only the suites it touches, and relies on the
gate for the rest. Raise the tier only when the finding shows the writer
was out of its depth.

## Two gates at a time

`gate.sh` takes one of `GATE_SLOTS` machine-wide slots (default 2; the
lock is `/tmp/<project>-gate.lock`) and then waits for the 1-minute load
to fall under 12 before it starts its suites. It began as one slot on
2026-10-06 and went to two the same night: with one gate running the
machine measured 84% idle, so the queue, not the processor, was the
limit. The end-to-end step has its own lock and never overlaps.
A harness's own final gate and a train's gate queue behind each other and
print `GATE_WAITING` while they wait. Without this, harnesses launched
together reach their gates together: on 2026-10-06 four gates side by side
took an 18-core machine to a load of 21, and Atomic's database health
probe (1 second to connect, 3 to answer, one retry) failed a stage on a
healthy server.

- A finished harness waiting in the queue costs nothing; do not stop a
  waiting gate.
- Only the writer runs the gate, once per round. A reviewer that reruns it
  doubles the queue: on 2026-10-06 three harnesses kept the one gate busy
  for 100 minutes this way. The launcher tells reviewers to read the
  writer's gate log instead; the train's gate is the independent run.
- When two harnesses are approved while a train waits for the gate, stop
  the waiting train and restack it with both (`EXTRA_CLONES`): one gate
  run instead of two.

## Pushing unattended

An SSH key held by a password manager's agent stops answering when its owner is away from the keyboard, even with the screen awake, so pushes hang overnight. Land on the seed anyway (the reviewer reads the seed, and says so in its report), and keep the landed clones until origin has their commits.

To push without the agent, point only the seed's push at HTTPS and let the GitHub CLI answer for it, in the seed's own config:

```bash
git config --local remote.origin.pushurl https://github.com/<owner>/<repo>.git
git config --local --replace-all credential.https://github.com.helper ""
git config --local --add credential.https://github.com.helper "!$(command -v gh) auth git-credential"
git push --dry-run origin main   # proves it without changing anything
```

Ask the user before changing how their repository authenticates. Always push with a time limit, so a prompt cannot hang the loop.
