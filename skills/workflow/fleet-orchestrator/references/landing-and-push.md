# Landing and push

Approved work is not delivered until it is on the seed's default branch, on
the remote, and green there. The orchestrator owns that last stretch.

## Batch landing train

One persistent landing lane lands the approved queue sequentially. The queue
is computed, never remembered (see [self-eval.md](self-eval.md)).

- **Waiting clones do nothing.** No speculative rebases, no gate reruns, no
  "getting ready" while another item lands. Every clone but the one in the
  slot is idle by design; work done ahead of the slot is thrown away by the
  next land and burns capacity twice.
- **Per-item gates are focused.** Each item runs the checks its own diff
  reaches, named by the project's gate matrix in the fleet config.
- **One full matrix at the batch tip.** After the last item lands and before
  the push, run the whole matrix once on the batch tip. Per-item green plus a
  clean rebase is not evidence that the combination is green.
- **A rebase that changes content changes the verdict.** If the rebase
  resolved conflicts, adjusted code, or moved behavior, the same reviewer
  re-verdicts the rebased range, scoped to the rebase.
- **A rebase that changes nothing transfers approval mechanically.** Compare
  patch identity across the rebase; identical patch IDs with no conflicts
  carry the existing approval, and no re-review is dispatched.
- **Mass-conflict changes take a solo slot.** A repository-wide rename or
  formatting sweep lands alone: nothing else lands in its window, because
  every other clone would need a re-review after it.
- **Derived-artifact chains land under a lock.** Where an artifact is
  generated from content and stamps the commit it was generated against,
  nothing else lands between the content commit and the end of the chain. Each
  generated artifact gets a **fresh commit naming its immediate published
  parent**. Never amend a commit an artifact stamp references, and never
  rebase a stamped commit: the stamp then points at a commit that exists only
  in one clone's reflog, so freshness passes locally and fails everywhere
  else. Regenerate against a clean tree; a generator that sees uncommitted
  files stamps itself dirty and the record is permanently stale.

## Push cadence

Push when all four hold, and not otherwise:

1. Unpushed commits exist on the seed's default branch.
2. CI is green on the current remote tip.
3. The batch-tip matrix is green locally.
4. No deployment run is in progress.

Then: fast-forward only, never a merge, never a force-push, and **arm the CI
watcher with the full SHA in the same turn**. A push with no live watcher is a
blind deploy.

- **One deployment in flight at a time.** Two pushes racing into the same
  environment produce a deploy whose result belongs to neither commit.
- **Red CI stops the train.** Fix forward on the seed, do not push again on
  top of an unexplained red, and never rewrite published history to clean up
  an old commit.
- **Deployments wipe hand-set environment state.** If a deploy re-applies
  configuration from a workflow or template, treat anything set by hand in the
  environment as lost at the next deploy and put it in the template instead —
  in the same change, alongside its runbook update.

## After the remote has it

- Clones stay unpushed; the seed is the only thing that pushes.
- Sweep clones whose branch tip is an ancestor of the default branch, whose
  tree is clean, and which no lane is using. Use the clone tool's own removal
  command, never a recursive delete: it refuses dirty trees and commits that
  exist nowhere else, which is exactly the mistake worth being refused.
- Record the landed tip as the **post-rebase seed SHA**, not the clone's
  pre-rebase tip. The queue reconciliation check is built on that convention.
