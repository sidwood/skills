# Branch checkout procedure

## Create and verify

1. Read `git bc-add -h` and locate the installed `git-bc-add` from the
   operator's dotfiles. If unavailable, repair that installation before
   creating a checkout; do not use raw clone, worktree, or copy commands.
   Even offline, BC requires the seed to have a configured upstream.
2. From the configured seed and the stream's `branch`, run
   `fleet checkout TICKET`. It calls `git bc-add --offline SEED BRANCH` and
   records the tool's default sibling checkout path, exact base, and creation
   command. Honor the configured branch and sibling-checkout naming
   conventions before creation; do not invent prefixes or namespaces
   absent from project configuration. BC owns extras synchronization
   and configured post-add hooks; inspect its output because a failed
   post-add hook can warn without a nonzero exit. Do not supply a nested
   replacement target or bypass those steps with a homemade script.
3. Check the resulting branch, accepted seed base, clean worktree, dependencies,
   and ignored prerequisites. Run `fleet checkouts check` before dispatch.
   The dispatch command repeats checkout validation before changing fleet
   state or creating a Herdr tab, including dry runs and capacity recovery.
4. Workers use the assigned checkout. Any additional diagnostic, recovery,
   implementer, or reviewer checkout follows this same creation path through
   the coordinator; workers do not create their own checkouts.

A valid checkout is a separate Git clone in the seed's parent directory,
with a seed-name prefix, the configured branch checked out, and a finite
`bc.source` chain ending at the configured seed. A raw clone, Git worktree,
seed checkout, wrong branch/source, or missing BC tool fails validation.
Existing valid BC sibling names may differ from the tool's default name.
Their approved base must belong to both the checkout and a verified source
in that chain; an intermediate source may contain work not yet in the seed.
Verification of an existing clone does not fabricate a creation receipt.

## Adopt an existing fleet

Run the checkout check before any new dispatch. Preserve active processes,
original paths, captures, and history while resolving drift. Terminal records
without live lanes are historical; they do not require recreating removed
clones. A planned checkout may be absent, but its configured layout must be
valid before creation.

When the operator explicitly permits an existing non-sibling BC checkout to
continue, record this exact per-stream allowance:

```json
"checkoutLegacyLayout": {
  "checkout": "/absolute/existing/checkout",
  "branch": "the-stream-branch",
  "seed": "/absolute/seed",
  "operatorAuthority": "Exact user instruction or link authorizing continuation"
}
```

This excuses only that existing path's layout. Branch identity, separate Git
directory, BC tooling, and source-chain checks still apply. It cannot create
or recreate a missing checkout, follow a changed path/branch/seed, or become
a blanket migration bypass. Retire the allowance when the existing work is
finished. New work uses normal sibling BC checkouts.

## Remove eligible clones

Read `git bc-list -h` and `git bc-rm -h` / `git bc-prune -h`. Recheck that
HEAD and every local branch are integrated into the ultimate seed, the tree
has no unique work, and no live pane/process or retained clone uses the path.
Preserve needed ignored evidence and recovery material before removal.
Then use the BC removal tool without force. Removal authority does not
permit bypassing dirty/unique-work safeguards, deleting active clones, or
pushing a repository.
