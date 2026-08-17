---
name: resolving-rebase-conflicts
description: Use when a Git rebase is paused by conflicts or the user asks to resolve rebase conflicts while preserving linear history. Do not use to create merge commits.
license: LICENSE
---

# Resolving Rebase Conflicts

Complete a conflicted rebase one replayed commit at a time without introducing
merge commits or discarding either side's intent.

## Workflow

1. **Confirm the operation.** Inspect `git status`, the rebase state, the original
   branch named by that state, the target history, and every unmerged path.
   Expect `HEAD` to be detached while commits are replayed. If no rebase is in
   progress, do not start one without the user's request.
2. **Recover both intentions.** Read the replayed commit message and patch,
   relevant target-branch commits, nearby code, tests, linked issues, and ADRs.
   Treat these as primary sources for what each side intended.
3. **Interpret stages correctly.** During a rebase, Git's usual labels are
   counterintuitive: `ours` is the target history plus commits already replayed,
   while `theirs` is the commit currently being replayed. Inspect the base and
   both stages rather than choosing by label.
4. **Resolve semantically.** Preserve compatible intentions, adapt the replayed
   change to the target's current interfaces, and avoid unrelated redesign. For
   rename/delete and generated-file conflicts, follow repository conventions and
   regenerate artifacts when that is safer than hand editing.
5. **Escalate incompatibility.** When both intentions cannot coexist and the
   desired product or architecture decision is not documented, stop and ask the
   user before choosing one.
6. **Verify and continue.** Stage only the paths resolved in this step. Inspect
   the staged diff, scan resolved paths for conflict markers, and run the
   narrowest useful checks before using `git rebase --continue`. Repeat the
   entire intent check for every later conflict because each replayed commit has
   a different purpose.
7. **Verify the result.** Run the repository's required checks, confirm the
   intended commits are present in order, confirm history remains linear, and
   report the final status.

## Rules

- Never run `git merge` or create a merge commit.
- Never resolve a whole file with `ours` or `theirs` without inspecting every
  conflicted hunk and its intent.
- Never use `git add -A`; stage resolved paths explicitly.
- Do not run `git rebase --abort`, `git rebase --skip`, change the rebase target,
  or force-push without explicit user authorization.
- Preserve unrelated working-tree and index changes.
