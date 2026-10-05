# Landing train

Land finished harness work in batches from outside Atomic. Each harness
already verified its own change; the train verifies the combination once.
First run on 2026-10-04 (two trains, four issues).

## Build

1. Take every harness that finished with all reviewers approving and a
   clean clone. Order them so an issue lands after the issues it depends on.
2. Make one staging clone from the seed, reused for later trains:

   ```bash
   git bc-add --offline <seed> train-1
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

Run the repository's own gate once on the staging tip, from the staging
clone's root: type check, lint, unit and integration suites. Record the
counts. Say plainly which suites were not run (for example end-to-end).

Run long gates in the background and chain the commands with `&&` so a
failure stops the run, and end the chain with a marker such as
`&& echo GATE_OK`. Land only when the output contains that marker: a
command placed after the chain (printing test counts, say) can make the
whole run exit 0 even though a check failed.

## Land

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
